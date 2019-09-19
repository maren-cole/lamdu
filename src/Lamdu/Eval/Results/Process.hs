{-# LANGUAGE TypeApplications, ScopedTypeVariables, TypeOperators #-}
module Lamdu.Eval.Results.Process
    ( addTypes
    ) where

import           AST
import           AST.Class.Has (HasChild(..))
import qualified AST.Class.Has as HasChild
import qualified AST.Term.Nominal as N
import           AST.Term.Row (RowExtend(..))
import qualified AST.Term.Row as Row
import           AST.Term.Scheme (sTyp, _QVarInstances, QVarInstances, Scheme)
import           AST.Unify.QuantifiedVar (HasQuantifiedVar(..))
import qualified Control.Lens as Lens
import           Data.Constraint (Dict(..), withDict)
import qualified Data.Map as Map
import qualified Data.Text as Text
import qualified Lamdu.Builtins.Anchors as Builtins
import qualified Lamdu.Calc.Type as T
import           Lamdu.Eval.Results (Val, Body(..))
import qualified Lamdu.Eval.Results as ER

import           Lamdu.Prelude

extractRecordTypeField :: T.Tag -> Tree Pure T.Type -> Maybe (Tree Pure T.Type, Tree Pure T.Type)
extractRecordTypeField tag typ =
    do
        flat <- typ ^? _Pure . T._TRecord . T.flatRow
        fieldType <- flat ^. Row.freExtends . Lens.at tag
        Just
            ( fieldType
            , _Pure . T._TRecord . T.flatRow # (flat & Row.freExtends . Lens.at tag .~ Nothing)
            )

extractVariantTypeField :: T.Tag -> Tree Pure T.Type -> Maybe (Tree Pure T.Type)
extractVariantTypeField tag typ =
    typ ^? _Pure . T._TVariant . T.flatRow
    >>= (^. Row.freExtends . Lens.at tag)

type AddTypes val f = (Tree Pure T.Type -> val -> f # Body) -> Tree Pure T.Type -> Body f

typeError :: String -> Body val
typeError = RError . ER.EvalTypeError . Text.pack

addTypesRecExtend ::
    Tree (RowExtend T.Tag val val) k ->
    (Tree Pure T.Type -> Tree k val -> Tree f Body) ->
    Tree Pure T.Type ->
    Tree Body f
addTypesRecExtend (RowExtend tag val rest) go typ =
    case extractRecordTypeField tag typ of
    Nothing ->
        -- TODO: this is a work-around for a bug. HACK
        -- we currently don't know types for eval results of polymorphic values
        case typ ^. _Pure of
        T.TVar{} ->
            RowExtend tag
            (go typ val)
            (go typ rest)
            & RRecExtend
        T.TInst{} ->
            -- Work around for MutRefs: todo better presentation which shows their current value?
            RRecEmpty
        _ -> "addTypesRecExtend got " ++ show typ & typeError
    Just (valType, restType) ->
        RowExtend tag
        (go valType val)
        (go restType rest)
        & RRecExtend

addTypesInject :: Tree ER.Inject (Ann a) -> AddTypes (Tree (Ann a) Body) f
addTypesInject (ER.Inject tag val) go typ =
    case extractVariantTypeField tag typ of
    Nothing ->
        -- TODO: this is a work-around for a bug. HACK
        -- we currently don't know types for eval results of polymorphic values
        case typ ^. _Pure of
        T.TVar{} -> go typ val & ER.Inject tag & RInject
        _ -> "addTypesInject got " ++ show typ & typeError
    Just valType -> go valType val & ER.Inject tag & RInject

addTypesArray :: [val] -> AddTypes val f
addTypesArray items go typ =
    case typ ^? _Pure . T._TInst . N.nArgs . HasChild.getChild . _QVarInstances . Lens.ix Builtins.valTypeParamId of
    Nothing ->
        -- TODO: this is a work-around for a bug. HACK
        -- we currently don't know types for eval results of polymorphic values
        case typ ^. _Pure of
        T.TVar{} -> items <&> go typ & RArray
        _ -> "addTypesArray got " ++ show typ & typeError
    Just paramType -> items <&> go paramType & RArray

addTypes :: Map T.NominalId (Tree Pure (N.NominalDecl T.Type)) -> Tree Pure T.Type -> Val () -> Val (Tree Pure T.Type)
addTypes nomsMap typ (Ann () b) =
    case b of
    RRecExtend recExtend -> r (addTypesRecExtend recExtend)
    RInject inject -> r (addTypesInject inject)
    RArray items -> r (addTypesArray items)
    RFunc x -> RFunc x
    RRecEmpty -> RRecEmpty
    RPrimVal l -> RPrimVal l
    RError e -> RError e
    & Ann typ
    where
        r f = f (addTypes nomsMap) (unwrapTInsts nomsMap typ)

class
    (KFunctor k, HasQuantifiedVar k, Ord (QVar k), HasChild T.Types k) =>
    ApplyNominal k where
    applyNominalRecursive :: Proxy k -> Dict (KNodesConstraint k ApplyNominal)
instance ApplyNominal T.Type where applyNominalRecursive _ = Dict
instance ApplyNominal T.Row where applyNominalRecursive _ = Dict

applyNominal ::
    Tree Pure (N.NominalDecl T.Type) ->
    Tree T.Types (QVarInstances Pure) ->
    Tree Pure (Scheme T.Types T.Type)
applyNominal nom params =
    _Pure # (nom ^. _Pure . N.nScheme & sTyp %~ subst params)

subst ::
    forall t.
    ApplyNominal t =>
    Tree T.Types (QVarInstances Pure) ->
    Tree Pure t ->
    Tree Pure t
subst params (Pure x) =
    withDict (applyNominalRecursive (Proxy @t)) $
    _Pure #
    case x ^? quantifiedVar of
    Nothing -> mapK (Proxy @ApplyNominal #> subst params) x
    Just q ->
        params ^?
        getChild . _QVarInstances . Lens.ix q . _Pure
        & fromMaybe (quantifiedVar # q)

-- Will loop forever for bottoms like: newtype Void = Void Void
unwrapTInsts :: Map T.NominalId (Tree Pure (N.NominalDecl T.Type)) -> Tree Pure T.Type -> Tree Pure T.Type
unwrapTInsts nomsMap typ =
    case typ ^. _Pure of
    T.TInst (N.NominalInst tid params) ->
        Map.lookup tid nomsMap
        <&> (\nominalInst -> applyNominal nominalInst params ^. _Pure . sTyp)
        <&> unwrapTInsts nomsMap
        & fromMaybe typ
    _ -> typ
