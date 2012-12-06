{-# LANGUAGE OverloadedStrings, PatternGuards #-}
module Editor.CodeEdit.DefinitionEdit(make) where

import Control.MonadA (MonadA)
import Data.List.Utils (nonEmptyAll)
import Data.Monoid (Monoid(..))
import Data.Store.Guid (Guid)
import Data.Traversable (traverse, sequenceA)
import Data.Vector.Vector2 (Vector2(..))
import Editor.CodeEdit.ExpressionEdit.ExpressionGui (ExpressionGui)
import Editor.CodeEdit.ExpressionEdit.ExpressionGui.Monad (ExprGuiM, WidgetT)
import Graphics.UI.Bottle.Widget (Widget)
import qualified Control.Lens as Lens
import qualified Data.List as List
import qualified Editor.BottleWidgets as BWidgets
import qualified Editor.CodeEdit.BuiltinEdit as BuiltinEdit
import qualified Editor.CodeEdit.ExpressionEdit.ExpressionGui as ExpressionGui
import qualified Editor.CodeEdit.ExpressionEdit.ExpressionGui.Monad as ExprGuiM
import qualified Editor.CodeEdit.ExpressionEdit.FuncEdit as FuncEdit
import qualified Editor.CodeEdit.Sugar as Sugar
import qualified Editor.Config as Config
import qualified Editor.WidgetEnvT as WE
import qualified Editor.WidgetIds as WidgetIds
import qualified Graphics.UI.Bottle.EventMap as E
import qualified Graphics.UI.Bottle.Widget as Widget
import qualified Graphics.UI.Bottle.Widgets.Box as Box
import qualified Graphics.UI.Bottle.Widgets.FocusDelegator as FocusDelegator

paramFDConfig :: FocusDelegator.Config
paramFDConfig = FocusDelegator.Config
  { FocusDelegator.startDelegatingKey = E.ModKey E.noMods E.KeyEnter
  , FocusDelegator.startDelegatingDoc = "Change parameter name"
  , FocusDelegator.stopDelegatingKey = E.ModKey E.noMods E.KeyEsc
  , FocusDelegator.stopDelegatingDoc = "Stop changing name"
  }

makeNameEdit ::
  MonadA m => (ExprGuiM.NameSource, String) -> Widget.Id -> Guid -> ExprGuiM m (WidgetT m)
makeNameEdit name myId ident =
  ExprGuiM.wrapDelegated paramFDConfig FocusDelegator.NotDelegating id
  (ExprGuiM.atEnv (WE.setTextColor Config.definitionOriginColor) .
   ExpressionGui.makeNameEdit name ident)
  myId

makeEquals :: MonadA m => Widget.Id -> ExprGuiM m (Widget f)
makeEquals = ExprGuiM.widgetEnv . BWidgets.makeLabel "=" . Widget.toAnimId

nonOperatorName :: (ExprGuiM.NameSource, String) -> Bool
nonOperatorName (ExprGuiM.StoredName, x) = nonEmptyAll (`notElem` Config.operatorChars) x
nonOperatorName _ = False

makeParts
  :: MonadA m
  => (ExprGuiM.NameSource, String)
  -> Guid
  -> Sugar.DefinitionContent m
  -> ExprGuiM m [ExpressionGui m]
makeParts name guid def = do
  nameEdit <-
    fmap
    (Widget.weakerEvents
     (FuncEdit.jumpToRHS Config.jumpLHStoRHSKeys rhs
      `mappend` addFirstParamEventMap) .
     jumpToRHSViaEquals name) $
    makeNameEdit name myId guid
  equals <- makeEquals myId
  (depParamsEdits, paramsEdits, bodyEdit) <-
    FuncEdit.makeParamsAndResultEdit
    jumpToRHSViaEquals lhs rhs myId depParams params
  return .
    List.intersperse (ExpressionGui.fromValueWidget BWidgets.stdSpaceWidget) $
    ExpressionGui.fromValueWidget nameEdit :
    depParamsEdits ++ paramsEdits ++
    [ ExpressionGui.fromValueWidget equals
    , Lens.over ExpressionGui.egWidget
      (Widget.weakerEvents addWhereItemEventMap)
      bodyEdit
    ]
  where
    jumpToRHSViaEquals n
      | nonOperatorName n =
        Widget.weakerEvents
        (FuncEdit.jumpToRHS [E.ModKey E.noMods (E.charKey '=')] rhs) .
        Lens.over Widget.wEventMap (E.filterChars (/= '='))
      | otherwise = id
    lhs = myId : map (WidgetIds.fromGuid . Lens.view Sugar.fpGuid) allParams
    rhs = ("Def Body", body)
    allParams = depParams ++ params
    Sugar.Func depParams params body = Sugar.dFunc def
    addWhereItemEventMap =
      Widget.keysEventMapMovesCursor Config.addWhereItemKeys "Add where item" .
      toEventMapAction $ Sugar.dAddInnermostWhereItem def
    addFirstParamEventMap =
      Widget.keysEventMapMovesCursor Config.addNextParamKeys "Add parameter" .
      toEventMapAction $ Sugar.dAddFirstParam def
    toEventMapAction =
      fmap (FocusDelegator.delegatingId . WidgetIds.fromGuid)
    myId = WidgetIds.fromGuid guid

make
  :: MonadA m
  => Sugar.Definition m
  -> ExprGuiM m (WidgetT m)
make def =
  case Sugar.drBody def of
  Sugar.DefinitionBodyExpression bodyExpr ->
    makeExprDefinition def bodyExpr
  Sugar.DefinitionBodyBuiltin builtin ->
    makeBuiltinDefinition def builtin

makeBuiltinDefinition
  :: MonadA m
  => Sugar.Definition m
  -> Sugar.DefinitionBuiltin m
  -> ExprGuiM m (WidgetT m)
makeBuiltinDefinition def builtin =
  fmap (Box.vboxAlign 0) $ sequenceA
  [ fmap BWidgets.hboxCenteredSpaced $ sequenceA
    [ ExprGuiM.withParamName guid $ \name -> makeNameEdit name (Widget.joinId myId ["name"]) guid
    , makeEquals myId
    , BuiltinEdit.make builtin myId
    ]
  , fmap (defTypeScale . Lens.view ExpressionGui.egWidget) .
    ExprGuiM.makeSubexpresion $ Sugar.drType def
  ]
  where
    guid = Sugar.drGuid def
    myId = WidgetIds.fromGuid guid

defTypeScale :: Widget f -> Widget f
defTypeScale = Widget.scale Config.defTypeBoxSizeFactor

makeWhereItemEdit :: MonadA m => Sugar.WhereItem m -> ExprGuiM m (WidgetT m)
makeWhereItemEdit item =
  fmap (Widget.weakerEvents eventMap) . assignCursor $
  makeDefBodyEdit (Sugar.wiGuid item) (Sugar.wiValue item)
  where
    assignCursor =
      foldr ((.) . (`ExprGuiM.assignCursor` myId) . WidgetIds.fromGuid) id $
      Sugar.wiHiddenGuids item
    myId = WidgetIds.fromGuid $ Sugar.wiGuid item
    eventMap
      | Just wiActions <- Sugar.wiActions item =
      mconcat
      [ Widget.keysEventMapMovesCursor (Config.delForwardKeys ++ Config.delBackwordKeys)
        "Delete where item" .
        fmap WidgetIds.fromGuid $
        Lens.view Sugar.itemDelete wiActions
      , Widget.keysEventMapMovesCursor Config.addWhereItemKeys
        "Add outer where item" .
        fmap WidgetIds.fromGuid $
        Lens.view Sugar.itemAddNext wiActions
      ]
      | otherwise = mempty

makeDefBodyEdit ::
  MonadA m => Guid -> Sugar.DefinitionContent m -> ExprGuiM m (WidgetT m)
makeDefBodyEdit guid content = do
  name <- ExprGuiM.getDefName guid
  body <- fmap (Lens.view ExpressionGui.egWidget . ExpressionGui.hbox) $
    makeParts name guid content
  wheres <-
    case Sugar.dWhereItems content of
    [] -> return []
    whereItems -> do
      whereLabel <-
        (fmap . Widget.scale) Config.whereLabelScaleFactor .
        ExprGuiM.widgetEnv . BWidgets.makeLabel "where" $ Widget.toAnimId myId
      itemEdits <- traverse makeWhereItemEdit $ reverse whereItems
      return
        [ BWidgets.hboxSpaced
          [ (0, whereLabel)
          , (0, Widget.scale Config.whereScaleFactor $ Box.vboxAlign 0 itemEdits)
          ]
        ]
  return . Box.vboxAlign 0 $ body : wheres
  where
    myId = WidgetIds.fromGuid guid

makeExprDefinition ::
  MonadA m => Sugar.Definition m -> Sugar.DefinitionExpression m ->
  ExprGuiM m (WidgetT m)
makeExprDefinition def bodyExpr = do
  typeWidgets <-
    case Sugar.deMNewType bodyExpr of
    Nothing
      | Sugar.deIsTypeRedundant bodyExpr -> return []
      | otherwise -> fmap ((:[]) . defTypeScale . BWidgets.hboxSpaced) (mkAcceptedRow id)
    Just (Sugar.DefinitionNewType inferredType acceptInferredType) ->
      fmap ((:[]) . defTypeScale . BWidgets.gridHSpaced) $ sequenceA
      [ mkAcceptedRow (>>= addAcceptanceArrow acceptInferredType)
      , mkTypeRow id "Inferred type:" inferredType
      ]
  bodyWidget <-
    makeDefBodyEdit guid $ Sugar.deContent bodyExpr
  return . Box.vboxAlign 0 $ typeWidgets ++ [bodyWidget]
  where
    addAcceptanceArrow acceptInferredType label = do
      acceptanceLabel <-
        (fmap . Widget.weakerEvents)
        (Widget.keysEventMapMovesCursor Config.acceptInferredTypeKeys
         "Accept inferred type" (acceptInferredType >> return myId)) .
        ExprGuiM.widgetEnv .
        BWidgets.makeFocusableTextView "↱" $ Widget.joinId myId ["accept type"]
      return $ BWidgets.hboxCenteredSpaced [acceptanceLabel, label]
    right = Vector2 1 0.5
    center = 0.5
    mkTypeRow onLabel labelText typeExpr = do
      label <-
        onLabel . labelStyle . ExprGuiM.widgetEnv .
        BWidgets.makeLabel labelText $ Widget.toAnimId myId
      typeGui <- ExprGuiM.makeSubexpresion typeExpr
      return
        [ (right, label)
        , (center, (Widget.doesntTakeFocus . Lens.view ExpressionGui.egWidget) typeGui)
        ]
    mkAcceptedRow onLabel = mkTypeRow onLabel "Type:" $ Sugar.drType def
    guid = Sugar.drGuid def
    myId = WidgetIds.fromGuid guid
    labelStyle =
      ExprGuiM.atEnv $ WE.setTextSizeColor Config.defTypeLabelTextSize Config.defTypeLabelColor
