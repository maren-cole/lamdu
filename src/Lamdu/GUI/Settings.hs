-- | Widget to edit the settings
{-# LANGUAGE TemplateHaskell, RankNTypes #-}
module Lamdu.GUI.Settings
    ( StatusWidgets(..), annotationWidget, themeWidget, languageWidget, helpWidget
    , TitledSelection(..), title, selection
    , hoist
    , makeStatusWidgets
    ) where

import qualified Control.Lens as Lens
import           Control.Lens.Extended (OneOf)
import           Data.Property (Property, composeLens)
import qualified GUI.Momentu.Animation.Id as AnimId
import qualified GUI.Momentu.Element as Element
import qualified GUI.Momentu.Glue as Glue
import qualified GUI.Momentu.Hover as Hover
import qualified GUI.Momentu.State as GuiState
import           GUI.Momentu.View (View)
import qualified GUI.Momentu.Widget.Id as WidgetId
import qualified GUI.Momentu.Widgets.Choice as Choice
import           GUI.Momentu.Widgets.EventMapHelp (IsHelpShown(..))
import qualified GUI.Momentu.Widgets.Label as Label
import           GUI.Momentu.Widgets.Spacer (HasStdSpacing)
import qualified GUI.Momentu.Widgets.TextView as TextView
import qualified Lamdu.Annotations as Ann
import           Lamdu.Config (Config)
import qualified Lamdu.Config as Config
import           Lamdu.Config.Folder (Selection, _Selection)
import qualified Lamdu.Config.Folder as Folder
import           Lamdu.Config.Theme (Theme)
import qualified Lamdu.GUI.StatusBar.Common as StatusBar
import           Lamdu.GUI.Styled (OneOfT(..))
import qualified Lamdu.GUI.Styled as Styled
import qualified Lamdu.I18N.CodeUI as Texts
import qualified Lamdu.I18N.StatusBar as Texts
import           Lamdu.Settings (Settings)
import qualified Lamdu.Settings as Settings

import           Lamdu.Prelude

data StatusWidgets f = StatusWidgets
    { _annotationWidget :: StatusBar.StatusWidget f
    , _themeWidget :: StatusBar.StatusWidget f
    , _languageWidget :: StatusBar.StatusWidget f
    , _helpWidget :: StatusBar.StatusWidget f
    }
Lens.makeLenses ''StatusWidgets

data TitledSelection a = TitledSelection
    { _title :: !Text
    , _selection :: !(Selection a)
    }
Lens.makeLenses ''TitledSelection

hoist ::
    (f GuiState.Update -> g GuiState.Update) ->
    StatusWidgets f -> StatusWidgets g
hoist f (StatusWidgets x y z a) =
    StatusWidgets (h x) (h y) (h z) (h a)
    where
        h = StatusBar.hoist f

unlabeledHeader ::
    Applicative f =>
    OneOf Texts.StatusBar ->
    OneOf Texts.StatusBar -> StatusBar.Header (f View)
unlabeledHeader switchLens categoryLens =
    StatusBar.Header
    { StatusBar.headerSwitchTextLens = switchLens
    , StatusBar.headerCategoryTextLens = categoryLens
    , StatusBar.headerWidget = pure Element.empty
    }

makeAnnotationsSwitcher ::
    ( MonadReader env m, Applicative f
    , Has Config env, Has Theme env
    , Has TextView.Style env
    , Has (Texts.StatusBar Text) env
    , Has (Choice.Texts Text) env
    , Has (Texts.CodeUI Text) env
    , Glue.HasTexts env
    , Element.HasAnimIdPrefix env, GuiState.HasCursor env, Has Hover.Style env
    ) =>
    Property f Ann.Mode -> m (StatusBar.StatusWidget f)
makeAnnotationsSwitcher annotationModeProp =
    do
        mk0 <- Styled.mkFocusableLabel
        mk1 <- Styled.mkFocusableLabel
        [ (Ann.Evaluation, mk0 (OneOf Texts.evaluation))
            , (Ann.Types, mk1 (OneOf Texts.sbTypes))
            , (Ann.None, mk1 (OneOf Texts.sbNone))
            ]
            & StatusBar.makeSwitchStatusWidget
            (StatusBar.labelHeader Texts.sbSwitchAnnotations Texts.sbAnnotations)
            Config.nextAnnotationModeKeys annotationModeProp

makeStatusWidgets ::
    ( MonadReader env m, Applicative f
    , Has Config env, Has Theme env, HasStdSpacing env
    , Element.HasAnimIdPrefix env, GuiState.HasCursor env, Has Hover.Style env
    , Has (Choice.Texts Text) env
    , Has (Texts.CodeUI Text) env
    , Has (Texts.StatusBar Text) env
    , Glue.HasTexts env
    ) =>
    [Selection Folder.Theme] -> [TitledSelection Folder.Language] ->
    Property f Settings -> m (StatusWidgets f)
makeStatusWidgets themeNames langNames prop =
    StatusWidgets
    <$> makeAnnotationsSwitcher (composeLens Settings.sAnnotationMode prop)
    <*> (traverse rawOpt themeNames
            >>= StatusBar.makeSwitchStatusWidget
            (unlabeledHeader Texts.sbSwitchTheme Texts.sbTheme)
            Config.changeThemeKeys themeProp)
    <*> (traverse opt langNames
            >>= StatusBar.makeSwitchStatusWidget
            (unlabeledHeader Texts.sbSwitchLanguage Texts.sbLanguage)
            Config.changeLanguageKeys langProp)
    <*> ( helpVals >>= StatusBar.makeSwitchStatusWidget
            (StatusBar.labelHeader Texts.sbSwitchHelp Texts.sbHelp)
            Config.helpKeys helpProp
        )
    where
        opt sel =
            (TextView.makeFocusable ?? (sel ^. title))
            <*> (Lens.view Element.animIdPrefix
                    <&> AnimId.augmentId (sel ^. selection)
                    <&> WidgetId.Id)
            <&> (,) (sel ^. selection)
        rawOpt sel = Label.makeFocusable (sel ^. _Selection) <&> (,) sel
        helpVals =
            Styled.mkFocusableLabel
            <&> \mk ->
            [ (HelpNotShown, OneOf Texts.hidden)
            , (HelpShown, OneOf Texts.shown)
            ] <&>
            _2 %~ \(OneOf lens) -> mk (OneOf lens)
        themeProp = composeLens Settings.sSelectedTheme prop
        langProp = composeLens Settings.sSelectedLanguage prop
        helpProp = composeLens Settings.sHelpShown prop
