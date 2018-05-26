{-# LANGUAGE FlexibleContexts #-}
module Lamdu.GUI.ExpressionEdit.InjectEdit
    ( make
    ) where

import qualified Control.Lens as Lens
import           GUI.Momentu.Align (WithTextPos)
import qualified GUI.Momentu.Element as Element
import qualified GUI.Momentu.EventMap as E
import           GUI.Momentu.Glue ((/|/))
import qualified GUI.Momentu.Responsive as Responsive
import qualified GUI.Momentu.Responsive.Expression as ResponsiveExpr
import qualified GUI.Momentu.Responsive.Options as Options
import qualified GUI.Momentu.State as GuiState
import           GUI.Momentu.View (View)
import qualified GUI.Momentu.Widget as Widget
import qualified GUI.Momentu.Widgets.TextView as TextView
import qualified Lamdu.Config as Config
import           Lamdu.Config.Theme (HasTheme)
import qualified Lamdu.GUI.ExpressionEdit.TagEdit as TagEdit
import           Lamdu.GUI.ExpressionGui (ExpressionGui)
import qualified Lamdu.GUI.ExpressionGui as ExprGui
import           Lamdu.GUI.ExpressionGui.Monad (ExprGuiM)
import qualified Lamdu.GUI.ExpressionGui.Monad as ExprGuiM
import           Lamdu.GUI.ExpressionGui.Wrap (stdWrapParentExpr)
import qualified Lamdu.GUI.Styled as Styled
import qualified Lamdu.GUI.WidgetIds as WidgetIds
import           Lamdu.Name (Name(..))
import           Lamdu.Sugar.NearestHoles (NearestHoles)
import qualified Lamdu.Sugar.Types as Sugar

import           Lamdu.Prelude

injectIndicator ::
    ( MonadReader env f, TextView.HasStyle env, HasTheme env
    , Element.HasAnimIdPrefix env
    ) => Text -> f (WithTextPos View)
injectIndicator text =
    (Styled.grammarText ?? text) <*> Element.subAnimId ["injectIndicator"]

makeInject ::
    (Monad i, Monad o) =>
    ExprGui.SugarExpr i o ->
    Sugar.Tag (Name o) i o ->
    Sugar.Payload (Name o) i o ExprGui.Payload ->
    ExprGuiM i o (ExpressionGui o)
makeInject val tag pl =
    stdWrapParentExpr pl <*>
    do
        disamb <-
            if pl ^. Sugar.plData . ExprGui.plNeedParens
            then ResponsiveExpr.disambiguators <*> Lens.view Element.animIdPrefix
            else pure Options.disambiguationNone
        arg <- ExprGuiM.makeSubexpression val
        colon <- injectIndicator ":"
        config <- Lens.view Config.config
        let replaceParentEventMap =
                -- Deleting the inject is replacing the whole expr
                -- with the injected value "child"
                case mReplaceParent of
                Nothing -> mempty
                Just replaceParent ->
                    replaceParent <&> WidgetIds.fromEntityId
                    & E.keysEventMapMovesCursor (Config.delKeys config) delDoc

        (Options.boxSpaced ?? disamb)
            <*>
            ( TagEdit.makeVariantTag nearestHoles tag
                <&> (/|/ colon)
                <&> Lens.mapped %~ Widget.weakerEvents replaceParentEventMap
                <&> Responsive.fromWithTextPos
                <&> (: [arg])
            )
    where
        nearestHoles = ExprGui.nextHolesBefore val
        delDoc = E.Doc ["Edit", "Delete"]
        mReplaceParent = val ^. Sugar.rPayload . Sugar.plActions . Sugar.mReplaceParent

emptyRec ::
    NearestHoles -> Sugar.NullaryVal name i o () ->
    Sugar.Expression name i o ExprGui.Payload
emptyRec nearestHoles (Sugar.NullaryVal pl closedActions addItem) =
    Sugar.Composite [] (Sugar.ClosedComposite closedActions) addItem
    & Sugar.BodyRecord
    & (`Sugar.Expression` pl')
    where
        pl' = pl <&> \() -> ExprGui.adhocPayload nearestHoles

makeNullaryInject ::
    (Monad i, Monad o) =>
    Sugar.NullaryVal (Name o) i o () ->
    Sugar.Tag (Name o) i o ->
    Sugar.Payload (Name o) i o ExprGui.Payload ->
    ExprGuiM i o (ExpressionGui o)
makeNullaryInject nullary tag pl =
    GuiState.isSubCursor ?? nullaryRecEntityId
    >>= \case
    True -> makeInject (emptyRec (pl ^. Sugar.plData . ExprGui.plNearestHoles) nullary) tag pl
    False ->
        stdWrapParentExpr pl <*>
        do
            dot <- injectIndicator "."
            TagEdit.makeVariantTag nearestHoles tag <&> (/|/ dot)
                <&> Responsive.fromWithTextPos
                <&> Widget.weakerEvents expandNullaryVal
    where
        expandNullaryVal =
            GuiState.updateCursor nullaryRecEntityId & pure & const
            & E.charGroup Nothing (E.Doc ["Edit", "Inject", "Value"]) ":"
        nullaryRecEntityId =
            nullary ^. Sugar.nullaryPayload . Sugar.plEntityId
            & WidgetIds.fromEntityId
        nearestHoles = pl ^. Sugar.plData . ExprGui.plNearestHoles

make ::
    (Monad i, Monad o) =>
    Sugar.Inject (Name o) i o (ExprGui.SugarExpr i o) ->
    Sugar.Payload (Name o) i o ExprGui.Payload ->
    ExprGuiM i o (ExpressionGui o)
make (Sugar.Inject tag mVal) =
    case mVal of
    Sugar.InjectNullary nullary -> makeNullaryInject nullary tag
    Sugar.InjectVal val -> makeInject val tag
