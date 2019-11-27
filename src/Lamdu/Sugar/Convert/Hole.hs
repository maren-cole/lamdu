{-# LANGUAGE ExistentialQuantification, TypeFamilies, PolyKinds #-}
{-# LANGUAGE ScopedTypeVariables, TypeOperators, TupleSections, TypeApplications #-}
module Lamdu.Sugar.Convert.Hole
    ( convert
      -- Used by Convert.Fragment:
    , Preconversion, ResultGen
    , ResultProcessor(..)
    , mkOptions, detachValIfNeeded, sugar, loadNewDeps
    , mkResult
    , mkOption, addWithoutDups
    , assertSuccessfulInfer
    ) where

import           Control.Applicative (Alternative(..))
import qualified Control.Lens as Lens
import           Control.Monad ((>=>), filterM)
import           Control.Monad.ListT (ListT)
import           Control.Monad.State (State, StateT(..), mapStateT, evalState, state)
import qualified Control.Monad.State as State
import           Control.Monad.Transaction (transaction)
import qualified Crypto.Hash.SHA256 as SHA256
import qualified Data.Binary.Extended as Binary
import           Data.Bits (xor)
import qualified Data.ByteString.Extended as BS
import           Data.CurAndPrev (CurAndPrev(..))
import qualified Data.List.Class as ListClass
import qualified Data.Map as Map
import           Data.Property (MkProperty')
import qualified Data.Property as Property
import           Data.Semigroup (Endo)
import qualified Data.Set as Set
import qualified Data.UUID as UUID
import           Hyper
import           Hyper.Infer (InferResult(..), inferResult)
import           Hyper.Recurse (wrap, unwrap)
import           Hyper.Type.AST.FuncType (FuncType(..))
import           Hyper.Type.AST.Nominal (NominalDecl, nScheme)
import           Hyper.Type.AST.Row (freExtends)
import           Hyper.Type.AST.Scheme (sTyp)
import           Hyper.Type.Functor (F(..), _F)
import           Hyper.Unify (Unify(..), BindingDict(..), unify)
import           Hyper.Unify.Apply (applyBindings)
import           Hyper.Unify.Binding (UVar)
import           Hyper.Unify.Term (UTerm(..), UTermBody(..))
import qualified Lamdu.Annotations as Annotations
import qualified Lamdu.Cache as Cache
import           Lamdu.Calc.Definition (Deps(..), depsGlobalTypes, depsNominals)
import           Lamdu.Calc.Infer (InferState, runPureInfer, PureInfer)
import qualified Lamdu.Calc.Lens as ExprLens
import           Lamdu.Calc.Term (Val)
import qualified Lamdu.Calc.Term as V
import           Lamdu.Calc.Term.Eq (couldEq)
import qualified Lamdu.Calc.Type as T
import qualified Lamdu.Data.Anchors as Anchors
import qualified Lamdu.Data.Definition as Def
import qualified Lamdu.Data.Definition as Definition
import qualified Lamdu.Expr.GenIds as GenIds
import           Lamdu.Expr.IRef (HRef(..), ValI, DefI)
import qualified Lamdu.Expr.IRef as ExprIRef
import qualified Lamdu.Expr.Load as Load
import           Lamdu.Sugar.Annotations (neverShowAnnotations, alwaysShowAnnotations)
import qualified Lamdu.Sugar.Config as Config
import           Lamdu.Sugar.Convert.Binder (convertBinder)
import           Lamdu.Sugar.Convert.Expression.Actions (addActions, convertPayload, makeSetToLiteral)
import           Lamdu.Sugar.Convert.Hole.ResultScore (resultScore)
import qualified Lamdu.Sugar.Convert.Hole.Suggest as Suggest
import qualified Lamdu.Sugar.Convert.Input as Input
import           Lamdu.Sugar.Convert.Monad (ConvertM)
import qualified Lamdu.Sugar.Convert.Monad as ConvertM
import           Lamdu.Sugar.Internal
import qualified Lamdu.Sugar.Internal.EntityId as EntityId
import           Lamdu.Sugar.Types
import           Revision.Deltum.IRef (IRef)
import qualified Revision.Deltum.IRef as IRef
import           Revision.Deltum.Transaction (Transaction)
import qualified Revision.Deltum.Transaction as Transaction
import           System.Random (random)
import qualified System.Random.Extended as Random
import           Text.PrettyPrint.HughesPJClass (prettyShow)

import           Lamdu.Prelude

type T = Transaction

type Preconversion m a =
    Ann (Input.Payload m a) # V.Term ->
    Ann (Input.Payload m ()) # V.Term

type ResultGen m = StateT InferState (ListT (T m))

convert ::
    (Monad m, Monoid a) =>
    ConvertM.PositionInfo -> Input.Payload m a # V.Term ->
    ConvertM m (ExpressionU m a)
convert posInfo holePl =
    Hole
    <$> mkOptions posInfo holeResultProcessor holePl
    <*> makeSetToLiteral holePl
    <*> pure Nothing
    <&> BodyHole
    >>= addActions [] holePl
    <&> annotation . pActions . mSetToHole .~ Nothing

data ResultProcessor m = forall a. ResultProcessor
    { rpEmptyPl :: a
    , rpPostProcess ::
        Ann (Const (Maybe (ValI m)) :*: InferResult UVar) # V.Term ->
        ResultGen m (Ann (Const (Maybe (ValI m), a) :*: InferResult UVar) # V.Term)
    , rpPreConversion :: Preconversion m a
    }

holeResultProcessor :: Monad m => ResultProcessor m
holeResultProcessor =
    ResultProcessor
    { rpEmptyPl = ()
    , rpPostProcess = pure . (hflipped . hmapped1 . Lens._1 . Lens._Wrapped %~ (, ()))
    , rpPreConversion = id
    }

mkOption ::
    Monad m =>
    ConvertM.Context m -> ResultProcessor m ->
    Input.Payload m a # V.Term -> Val () ->
    HoleOption InternalName (T m) (T m)
mkOption sugarContext resultProcessor holePl x =
    HoleOption
    { _hoVal = x
    , _hoSugaredBaseExpr = sugar sugarContext holePl x
    , _hoResults = mkResults resultProcessor sugarContext holePl x
    }

mkHoleSuggesteds ::
    Monad m =>
    ConvertM.Context m -> ResultProcessor m ->
    Input.Payload m a # V.Term ->
    [HoleOption InternalName (T m) (T m)]
mkHoleSuggesteds sugarContext resultProcessor holePl =
    holePl ^. Input.inferRes . inferResult . Lens._2
    & Suggest.forType
    & runPureInfer (holePl ^. Input.inferScope) inferContext

    -- TODO: Change ConvertM to be stateful rather than reader on the
    -- sugar context, to collect union-find updates.
    -- TODO: use a specific monad here that has no Either
    & assertSuccessfulInfer
    & fst
    <&> hflipped . hmapped1 .~ Const () -- TODO: "Avoid re-inferring known type here"
    <&> mkOption sugarContext resultProcessor holePl
    where
        inferContext = sugarContext ^. ConvertM.scInferContext

strip :: Recursively HFunctor h => Ann a # h -> Pure # h
strip = unwrap (const (^. hVal))

addWithoutDups ::
    [HoleOption i o a] -> [HoleOption i o a] -> [HoleOption i o a]
addWithoutDups new old
    | null nonHoleNew = old
    | otherwise = nonHoleNew ++ filter (not . equivalentToNew) old
    where
        equivalentToNew x =
            any (couldEq (strip (x ^. hoVal))) (nonHoleNew ^.. Lens.traverse . hoVal <&> strip)
        nonHoleNew = filter (Lens.nullOf (hoVal . ExprLens.valHole)) new

isLiveGlobal :: Monad m => DefI m -> T m Bool
isLiveGlobal defI =
    Anchors.assocDefinitionState defI
    & Property.getP
    <&> (== LiveDefinition)

getListing ::
    Monad m =>
    (Anchors.CodeAnchors f -> MkProperty' (T m) (Set a)) ->
    ConvertM.Context f -> T m [a]
getListing anchor sugarContext =
    sugarContext ^. Anchors.codeAnchors
    & anchor & Property.getP <&> Set.toList

getNominals :: Monad m => ConvertM.Context m -> T m [(T.NominalId, Pure # NominalDecl T.Type)]
getNominals sugarContext =
    getListing Anchors.tids sugarContext
    >>= traverse (\nomId -> (,) nomId <$> Load.nominal nomId)
    <&> map (Lens.sequenceAOf Lens._2) <&> (^.. traverse . Lens._Just)

getGlobals :: Monad m => ConvertM.Context m -> T m [DefI m]
getGlobals sugarContext =
    getListing Anchors.globals sugarContext >>= filterM isLiveGlobal

getTags :: Monad m => ConvertM.Context m -> T m [T.Tag]
getTags = getListing Anchors.tags

mkNominalOptions :: [(T.NominalId, Pure # NominalDecl T.Type)] -> [HPlain V.Term]
mkNominalOptions nominals =
    do
        (tid, Pure nominal) <- nominals
        mkDirectNoms tid ++ mkToNomInjections tid nominal
    where
        mkDirectNoms tid =
            [ V.BLeafP (V.LFromNom tid) `V.BAppP` V.BLeafP V.LHole
            , V.BLeafP V.LHole & V.BToNomP tid
            ]
        mkToNomInjections tid nominal =
            nominal ^..
            nScheme . sTyp . _Pure . T._TVariant .
            T.flatRow . freExtends >>= Map.keys
            <&> (`V.BInjectP` V.BLeafP V.LHole)
            <&> V.BToNomP tid

mkOptions ::
    Monad m =>
    ConvertM.PositionInfo -> ResultProcessor m ->
    Input.Payload m a # V.Term ->
    ConvertM m (T m [HoleOption InternalName (T m) (T m)])
mkOptions posInfo resultProcessor holePl =
    Lens.view id
    <&>
    \sugarContext ->
    do
        nominalOptions <- getNominals sugarContext <&> mkNominalOptions
        globals <- getGlobals sugarContext
        tags <- getTags sugarContext
        concat
            [ holePl ^. Input.localsInScope >>= getLocalScopeGetVars sugarContext
            , globals <&> V.BLeafP . V.LVar . ExprIRef.globalId
            , tags <&> (`V.BInjectP` V.BLeafP V.LHole)
            , nominalOptions
            , [ V.BLamP "NewLambda" (V.BLeafP V.LHole)
              , V.BLeafP V.LRecEmpty
              , V.BLeafP V.LAbsurd
              ]
            , [ V.BLamP "NewLambda" (V.BLeafP V.LHole) `V.BAppP` V.BLeafP V.LHole
              | posInfo == ConvertM.BinderPos
              ]
            ]
            <&> wrap (const (Ann (Const ()))) . (^. hPlain)
            <&> mkOption sugarContext resultProcessor holePl
            & addWithoutDups (mkHoleSuggesteds sugarContext resultProcessor holePl)
            & pure

-- TODO: Generalize into a separate module?
loadDeps :: Monad m => [V.Var] -> [T.NominalId] -> T m Deps
loadDeps vars noms =
    Deps
    <$> (traverse loadVar vars <&> Map.fromList)
    <*> (traverse loadNom noms <&> Map.fromList)
    where
        loadVar globalId =
            ExprIRef.defI globalId & Transaction.readIRef
            <&> (^. Def.defType) <&> (,) globalId
        loadNom nomId =
            Load.nominal nomId
            <&> fromMaybe (error "Opaque nominal used!")
            <&> (,) nomId

type Getting' r a = Lens.Getting a r a
type Folding' r a = Lens.Getting (Endo [a]) r a

-- TODO: Generalize into a separate module?
loadNewDeps ::
    forall m a k.
    Monad m => Deps -> V.Scope # k -> Ann a # V.Term -> T m Deps
loadNewDeps currentDeps scope x =
    loadDeps newDepVars newNoms
    <&> mappend currentDeps
    where
        scopeVars = scope ^. V.scopeVarTypes & Map.keysSet
        newDeps ::
            Ord r =>
            Getting' Deps (Map r x) -> Folding' (Ann (Const ()) # V.Term) r -> [r]
        newDeps depsLens valLens =
            Set.fromList ((x & hflipped . hmapped1 .~ Const ()) ^.. valLens)
            `Set.difference` Map.keysSet (currentDeps ^. depsLens)
            & Set.toList
        newDepVars = newDeps depsGlobalTypes (ExprLens.valGlobals scopeVars)
        newNoms = newDeps depsNominals ExprLens.valNominals

-- Unstored and without eval results.
-- Used for hole's base exprs, to perform sugaring and get names from sugared exprs.
-- TODO: We shouldn't need to perform sugaring for base exprs, and this should be removed.
prepareUnstoredPayloads ::
    Val (InferResult (Pure :*: UVar) # V.Term, EntityId, a) ->
    Ann (Input.Payload m a) # V.Term
prepareUnstoredPayloads v =
    v & hflipped . hmapped1 %~ mk . getConst & Input.preparePayloads
    where
        mk (inferPl, eId, x) =
            Input.PreparePayloadInput
            { Input.ppEntityId = eId
            , Input.ppMakePl =
                \varRefs ->
                Input.Payload
                { Input._varRefsOfLambda = varRefs
                , Input._userData = x
                , Input._localsInScope = []
                , Input._inferRes = inferPl
                , Input._inferScope = V.emptyScope
                , Input._entityId = eId
                , Input._stored =
                    HRef
                    (_F # IRef.unsafeFromUUID fakeStored)
                    (error "stored output of base expr used!")
                , Input._evalResults =
                    CurAndPrev Input.emptyEvalResults Input.emptyEvalResults
                }
            }
            where
                -- TODO: Which code reads this?
                EntityId.EntityId fakeStored = eId

assertSuccessfulInfer ::
    HasCallStack =>
    Either (Pure # T.TypeError) a -> a
assertSuccessfulInfer = either (error . prettyShow) id

loadInfer ::
    Monad m =>
    ConvertM.Context m -> V.Scope # UVar ->
    Ann a # V.Term ->
    T m (Deps, Either (Pure # T.TypeError)
        ((Ann (a :*: InferResult UVar) # V.Term, V.Scope # UVar), InferState))
loadInfer sugarContext scope v =
    loadNewDeps sugarDeps scope v
    <&>
    \deps ->
    ( deps
    , memoInfer (Definition.Expr v deps)
        & runPureInfer scope (sugarContext ^. ConvertM.scInferContext)
    )
    where
        memoInfer = Cache.infer (sugarContext ^. ConvertM.scCacheFunctions)
        sugarDeps = sugarContext ^. ConvertM.scFrozenDeps . Property.pVal

sugar ::
    (Monad m, Monoid a) =>
    ConvertM.Context m -> Input.Payload m dummy # V.Term -> Val a ->
    T m (Annotated (Payload InternalName (T m) (T m) a) (Binder InternalName (T m) (T m)))
sugar sugarContext holePl v =
    do
        (val, inferCtx) <-
            loadInfer sugarContext scope v
            <&> snd
            <&> assertSuccessfulInfer
            <&>
            ( \((term, topLevelScope), inferCtx) ->
                ( (hflipped . htraverse1) mkPayload term
                    & runPureInfer scope inferCtx
                    & assertSuccessfulInfer
                    & fst
                    & EntityId.randomizeExprAndParams
                        (Random.genFromHashable (holePl ^. Input.entityId))
                    & prepareUnstoredPayloads
                    & Input.initScopes inferCtx topLevelScope (holePl ^. Input.localsInScope)
                , inferCtx
                )
            ) & transaction
        convertBinder val
            <&> hflipped %~ hmap (const (Lens._Wrapped %~ (,) neverShowAnnotations))
            >>= hflipped (htraverse (const (Lens._Wrapped convertPayload)))
            & ConvertM.run
                (sugarContext
                    & ConvertM.scInferContext .~ inferCtx
                    & ConvertM.scAnnotationsMode .~ Annotations.None
                )
    where
        scope = holePl ^. Input.inferScope
        mkPayload ::
            (Const a :*: InferResult UVar) # V.Term ->
            PureInfer (V.Scope # UVar)
                (Const (EntityId -> (InferResult (Pure :*: UVar) # V.Term, EntityId, a)) # V.Term)
        mkPayload (Const x :*: inferPl) =
            hflipped
            (htraverse (Proxy @(Unify (PureInfer (V.Scope # UVar))) #> \i -> applyBindings i <&> (:*: i)))
            inferPl
            <&> (\r entityId -> (r, entityId, x))
            <&> Const

getLocalScopeGetVars :: ConvertM.Context m -> V.Var -> [HPlain V.Term]
getLocalScopeGetVars sugarContext par
    | sugarContext ^. ConvertM.scScopeInfo . ConvertM.siNullParams . Lens.contains par = []
    | otherwise = (fieldTags <&> V.BGetFieldP var) <> [var]
    where
        var = V.LVar par & V.BLeafP
        fieldTags =
            ( sugarContext ^@..
                ConvertM.scScopeInfo . ConvertM.siTagParamInfos .>
                ( Lens.itraversed <.
                    ConvertM._TagFieldParam . Lens.to ConvertM.tpiFromParameters ) <.
                    Lens.filtered (== par)
            ) <&> fst

-- | Runs inside a forked transaction
writeResult ::
    Monad m =>
    Preconversion m a -> InferState -> HRef m # V.Term ->
    Ann (Const (Maybe (ValI m), a) :*: InferResult UVar) # V.Term ->
    T m (Ann (Input.Payload m ()) # V.Term)
writeResult preConversion inferContext holeStored inferredVal =
    do
        writtenExpr <-
            inferredVal
            & hflipped . hmapped1 %~ intoStorePoint
            & writeExprMStored (holeStored ^. ExprIRef.iref)
            <&> ExprIRef.toHRefs (holeStored ^. ExprIRef.setIref)
            <&> addBindingsAll
            <&> hflipped . hmapped1 %~ toPayload
            <&> Input.preparePayloads
        (holeStored ^. ExprIRef.setIref) (writtenExpr ^. hAnn . Input.stored . ExprIRef.iref)
        preConversion writtenExpr & pure
    where
        intoStorePoint (Const (mStorePoint, a) :*: inferred) =
            maybe ExprIRef.WriteNew ExprIRef.ExistingRef mStorePoint :*:
            Const (inferred, a)
        toPayload (stored :*: Const (inferRes, a)) =
            -- TODO: Evaluate hole results instead of Map.empty's?
            Input.PreparePayloadInput
            { Input.ppEntityId = eId
            , Input.ppMakePl =
                \varRefs ->
                Input.Payload
                { Input._varRefsOfLambda = varRefs
                , Input._userData = a
                , Input._inferRes = inferRes
                , Input._inferScope = V.emptyScope -- TODO: HACK
                , Input._evalResults = CurAndPrev noEval noEval
                , Input._stored = stored
                , Input._entityId = eId
                , Input._localsInScope = []
                }
            }
            where
                eId = stored ^. ExprIRef.iref & EntityId.ofValI
        noEval = Input.EvalResultsForExpr Map.empty Map.empty
        addBindingsAll ::
            Ann (HRef m :*: Const (InferResult UVar # V.Term, a)) # V.Term ->
            Ann (HRef m :*: Const (InferResult (Pure :*: UVar) # V.Term, a)) # V.Term
        addBindingsAll x =
            (hflipped . htraverse1 . Lens._2 . Lens._Wrapped) addBindings x
            & runPureInfer () inferContext
            & assertSuccessfulInfer
            & fst
        addBindings ::
            (InferResult UVar # V.Term, a) ->
            PureInfer () (InferResult (Pure :*: UVar) # V.Term, a)
        addBindings (inferRes, a) =
            hflipped
            (htraverse (Proxy @(Unify (PureInfer ())) #> \i -> applyBindings i <&> (:*: i)))
            inferRes
            <&> (, a)

detachValIfNeeded ::
    a -> UVar # T.Type -> Ann (Const a :*: InferResult UVar) # V.Term ->
    -- TODO: PureInfer?
    State InferState (Ann (Const a :*: InferResult UVar) # V.Term)
detachValIfNeeded emptyPl holeType x =
    do
        unifyRes <-
            do
                r <- unify holeType xType
                -- Verify occurs checks.
                -- TODO: share with applyBindings that happens for sugaring.
                s <- State.get
                _ <-
                    x ^.. hflipped . hfolded1 . Lens._2 . inferResult
                    & traverse_ applyBindings
                r <$ State.put s
            & liftPureInfer
        let mkFragmentExpr =
                FuncType xType holeType & T.TFun
                & UTermBody mempty & UTerm & newVar binding
                <&> \funcType ->
                let withTyp typ = Ann (Const emptyPl :*: inferResult # typ)
                    func = V.BLeaf V.LHole & withTyp funcType
                in  func `V.App` x & V.BApp & withTyp holeType
        case unifyRes of
            Right{} -> pure x
            Left{} ->
                liftPureInfer mkFragmentExpr
                <&> assertSuccessfulInfer
    where
        xType = x ^. hAnn . _2 . inferResult
        liftPureInfer ::
            PureInfer () a -> State InferState (Either (Pure # T.TypeError) a)
        liftPureInfer act =
            do
                st <- Lens.use id
                runPureInfer () st act
                    & Lens._Right %%~ \(r, newSt) -> r <$ (id .= newSt)

mkResultVals ::
    Monad m =>
    ConvertM.Context m -> V.Scope # UVar -> Val () ->
    ResultGen m (Deps, Ann (Const (Maybe (ValI m)) :*: InferResult UVar) # V.Term)
mkResultVals sugarContext scope seed =
    -- TODO: This uses state from context but we're in StateT.
    -- This is a mess..
    loadInfer sugarContext scope seed & txn
    >>=
    \case
    (_, Left{}) -> empty
    (newDeps, Right ((i, _), newInferState)) ->
        do
            id .= newInferState
            form <-
                Suggest.termTransformsWithModify (Const ()) i
                & mapStateT ListClass.fromList
            pure (newDeps, form & hflipped . hmapped1 . _1 .~ Const Nothing)
    where
        txn = lift . lift

mkResult ::
    Monad m =>
    Preconversion m a -> ConvertM.Context m -> T m () ->
    Input.Payload m b # V.Term ->
    Ann (Const (Maybe (ValI m), a) :*: InferResult UVar) # V.Term ->
    T m (HoleResult InternalName (T m) (T m))
mkResult preConversion sugarContext updateDeps holePl x =
    do
        updateDeps
        writeResult preConversion (sugarContext ^. ConvertM.scInferContext)
            (holePl ^. Input.stored) x
        <&> Input.initScopes (sugarContext ^. ConvertM.scInferContext)
                (holePl ^. Input.inferScope)
                    -- TODO: this is kind of wrong
                    -- The scope for a proper term should be from after loading its infer deps
                    -- But that's only necessary for suggesting hole results?
                    -- And we are in a hole result here
                (holePl ^. Input.localsInScope)
        <&> (convertBinder >=> hflipped (htraverse (const (Lens._Wrapped convertPayload))) . (hflipped %~ hmap (const (Lens._Wrapped %~ (,) showAnn))))
        >>= ConvertM.run (sugarContext & ConvertM.scAnnotationsMode .~ Annotations.None)
        & Transaction.fork
        <&> \(fConverted, forkedChanges) ->
        HoleResult
        { _holeResultConverted = fConverted
        , _holeResultPick =
            do
                Transaction.merge forkedChanges
                -- TODO: Remove this 'run', mkResult to be wholly in ConvertM
                ConvertM.run sugarContext ConvertM.postProcessAssert & join
        }
    where
        showAnn
            | sugarContext ^. ConvertM.scConfig . Config.showAllAnnotations = alwaysShowAnnotations
            | otherwise = neverShowAnnotations

toStateT :: Applicative m => State s a -> StateT s m a
toStateT = mapStateT $ \(Lens.Identity act) -> pure act

toScoredResults ::
    (Monad f, Monad m) =>
    a -> Preconversion m a -> ConvertM.Context m ->
    Input.Payload m dummy # V.Term ->
    StateT InferState f (Deps, Ann (Const (Maybe (ValI m), a) :*: InferResult UVar) # V.Term) ->
    f ( HoleResultScore
      , T m (HoleResult InternalName (T m) (T m))
      )
toScoredResults emptyPl preConversion sugarContext holePl act =
    act
    >>= _2 %%~
        toStateT .
        detachValIfNeeded (Nothing, emptyPl) (holePl ^. Input.inferRes. inferResult . Lens._2)
    & (`runStateT` (sugarContext ^. ConvertM.scInferContext))
    <&> \((newDeps, x), inferContext) ->
    let newSugarContext =
            sugarContext
            & ConvertM.scInferContext .~ inferContext
            & ConvertM.scFrozenDeps . Property.pVal .~ newDeps
        updateDeps = newDeps & sugarContext ^. ConvertM.scFrozenDeps . Property.pSet
    in  ( x & hflipped . htraverse1 %%~ fmap Const . applyBindings . (^. Lens._2 . inferResult)
          & runPureInfer (holePl ^. Input.inferScope) inferContext
          & assertSuccessfulInfer
          & fst
          & resultScore
        , mkResult preConversion newSugarContext updateDeps holePl x
        )

mkResults ::
    Monad m =>
    ResultProcessor m -> ConvertM.Context m ->
    Input.Payload m dummy # V.Term -> Val () ->
    ListT (T m)
    ( HoleResultScore
    , T m (HoleResult InternalName (T m) (T m))
    )
mkResults (ResultProcessor emptyPl postProcess preConversion) sugarContext holePl base =
    mkResultVals sugarContext (holePl ^. Input.inferScope) base
    >>= _2 %%~ postProcess
    & toScoredResults emptyPl preConversion sugarContext holePl

xorBS :: ByteString -> ByteString -> ByteString
xorBS x y = BS.pack $ BS.zipWith xor x y

randomizeNonStoredParamIds ::
    Random.StdGen ->
    Ann (ExprIRef.Write m :*: a) # V.Term ->
    Ann (ExprIRef.Write m :*: a) # V.Term
randomizeNonStoredParamIds gen =
    GenIds.randomizeParamIdsG id nameGen Map.empty
    where
        nameGen = GenIds.onNgMakeName f $ GenIds.randomNameGen gen
        f n _        prevEntityId (ExprIRef.ExistingRef{} :*: _) = (prevEntityId, n)
        f _ prevFunc prevEntityId pl@(ExprIRef.WriteNew :*: _) = prevFunc prevEntityId pl

randomizeNonStoredRefs ::
    ByteString ->
    Random.StdGen ->
    Ann (ExprIRef.Write m :*: a) # V.Term ->
    Ann (ExprIRef.Write m :*: a) # V.Term
randomizeNonStoredRefs uniqueIdent gen v =
    evalState ((hflipped . htraverse1 . _1) f v) gen
    where
        f ExprIRef.WriteNew =
            state random
            <&> UUID.toByteString <&> BS.strictify
            <&> xorBS uniqueIdent
            <&> BS.lazify <&> UUID.fromByteString
            <&> fromMaybe (error "cant parse UUID")
            <&> IRef.unsafeFromUUID <&> F <&> ExprIRef.ExistingRef
        f (ExprIRef.ExistingRef x) = ExprIRef.ExistingRef x & pure

writeExprMStored ::
    Monad m =>
    ValI m ->
    Ann (ExprIRef.Write m :*: a) # V.Term ->
    T m (Ann (F (IRef m) :*: a) # V.Term)
writeExprMStored exprIRef exprMStorePoint =
    exprMStorePoint
    & randomizeNonStoredParamIds genParamIds
    & randomizeNonStoredRefs uniqueIdent genRefs
    & ExprIRef.writeRecursively
    where
        uniqueIdent =
            Binary.encode
            ( exprMStorePoint & hflipped . hmapped1 %~ Const . (^. _1)
            , exprIRef
            )
            & SHA256.hashlazy
        (genParamIds, genRefs) = Random.genFromHashable uniqueIdent & Random.split
