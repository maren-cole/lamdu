{-# LANGUAGE TemplateHaskell #-}
module Editor.Data
  ( Definition(..), atDefBody, atDefType
  , DefinitionI, DefinitionIRef
  , FFIName(..)
  , VariableRef(..), variableRefGuid
  , Lambda(..), atLambdaParamType, atLambdaBody
  , LambdaI
  , Apply(..), atApplyFunc, atApplyArg
  , ApplyI
  , Expression(..)
  , ExpressionI, ExpressionIRef(..)
  , newExprIRef, readExprIRef, writeExprIRef, exprIRefGuid
  , foldMExpression
  , mapMExpression
  ) where

import Control.Monad (liftM, liftM2)
import Data.Binary (Binary(..))
import Data.Binary.Get (getWord8)
import Data.Binary.Put (putWord8)
import Data.Derive.Binary(makeBinary)
import Data.DeriveTH(derive)
import Data.Store.Guid (Guid)
import Data.Store.IRef(IRef)
import Data.Store.Transaction (Transaction)
import qualified Data.AtFieldTH as AtFieldTH
import qualified Data.Store.IRef as IRef
import qualified Data.Store.Transaction as Transaction

newtype ExpressionIRef = ExpressionIRef {
  unExpressionIRef :: IRef (Expression ExpressionIRef)
  } deriving (Eq, Ord, Show)

exprIRefGuid :: ExpressionIRef -> Guid
exprIRefGuid = IRef.guid . unExpressionIRef

newExprIRef
  :: Monad m
  => Expression ExpressionIRef -> Transaction t m ExpressionIRef
newExprIRef = liftM ExpressionIRef . Transaction.newIRef

readExprIRef
  :: Monad m
  => ExpressionIRef -> Transaction t m (Expression ExpressionIRef)
readExprIRef = Transaction.readIRef . unExpressionIRef

writeExprIRef
  :: Monad m
  => ExpressionIRef -> Expression ExpressionIRef -> Transaction t m ()
writeExprIRef = Transaction.writeIRef . unExpressionIRef

data Lambda expr = Lambda {
  lambdaParamType :: expr,
  lambdaBody :: expr
  } deriving (Eq, Ord, Show)
type LambdaI = Lambda ExpressionIRef

data Apply expr = Apply {
  applyFunc :: expr,
  applyArg :: expr
  } deriving (Eq, Ord, Show)
type ApplyI = Apply ExpressionIRef

data VariableRef
  = ParameterRef Guid -- of the lambda/pi
  | DefinitionRef DefinitionIRef
  deriving (Eq, Ord, Show)

data FFIName = FFIName
  { fModule :: [String]
  , fName :: String
  } deriving (Eq, Ord)

instance Show FFIName where
  show (FFIName path name) = concatMap (++".") path ++ name

data Expression expr
  = ExpressionLambda (Lambda expr)
  | ExpressionPi (Lambda expr)
  | ExpressionApply (Apply expr)
  | ExpressionGetVariable VariableRef
  | ExpressionHole
  | ExpressionLiteralInteger Integer
  | ExpressionBuiltin FFIName
  | ExpressionMagic
  deriving (Eq, Ord, Show)
type ExpressionI = Expression ExpressionIRef

data FoldExpression m from to = FoldExpression
  { feDeref :: m (Expression from)
  , feLambda :: Lambda to -> m to
  , fePi :: Lambda to -> m to
  , feApply :: Apply to -> m to
  , feGetVariable :: VariableRef -> m to
  , feHole :: m to
  , feLiteralInt :: Integer -> m to
  , feBuiltin :: FFIName -> m to
  , feMagic :: m to
  }

data Definition expr = Definition
  { defType :: expr
  , defBody :: expr
  } deriving (Eq, Ord, Show)
type DefinitionI = Definition ExpressionIRef
type DefinitionIRef = IRef DefinitionI

variableRefGuid :: VariableRef -> Guid
variableRefGuid (ParameterRef i) = i
variableRefGuid (DefinitionRef i) = IRef.guid i

derive makeBinary ''ExpressionIRef
derive makeBinary ''FFIName
derive makeBinary ''VariableRef
derive makeBinary ''Lambda
derive makeBinary ''Apply
derive makeBinary ''Expression
derive makeBinary ''Definition
AtFieldTH.make ''Lambda
AtFieldTH.make ''Apply
AtFieldTH.make ''Definition


foldMExpression
  :: Monad m
  => (from -> FoldExpression m from to)
  -> from
  -> m to
foldMExpression mkFolder exprI = do
  expr <- feDeref folder
  case expr of
    ExpressionLambda l -> feLambda folder =<< foldLambda l
    ExpressionPi l -> fePi folder =<< foldLambda l
    ExpressionApply (Apply func arg) ->
      feApply folder =<< liftM2 Apply (recurse func) (recurse arg)
    ExpressionGetVariable varRef -> feGetVariable folder varRef
    ExpressionHole -> feHole folder
    ExpressionLiteralInteger int -> feLiteralInt folder int
    ExpressionBuiltin ffiName -> feBuiltin folder ffiName
    ExpressionMagic -> feMagic folder
  where
    folder = mkFolder exprI
    recurse = foldMExpression mkFolder
    foldLambda (Lambda p b) = liftM2 Lambda (recurse p) (recurse b)

mapMExpression
  :: Monad m
  => (from
      -> ( m (Expression from)
         , Expression to -> m to ))
  -> from -> m to
mapMExpression f =
  foldMExpression mkFolder
  where
    mkFolder src = FoldExpression
      { feDeref = deref
      , feLambda = g . ExpressionLambda
      , fePi = g . ExpressionPi
      , feApply = g . ExpressionApply
      , feGetVariable = g . ExpressionGetVariable
      , feHole = g ExpressionHole
      , feLiteralInt = g . ExpressionLiteralInteger
      , feBuiltin = g . ExpressionBuiltin
      , feMagic = g ExpressionMagic
      }
      where
        (deref, g) = f src
