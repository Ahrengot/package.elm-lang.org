module Main exposing (..)


import Browser
import Browser.History as History
import Html exposing (..)
import Html.Attributes exposing (..)
import Html.Lazy exposing (..)
import Page.Docs as Docs
import Page.Diff as Diff
import Page.Problem as Problem
import Route
import Session
import Session.Query as Query
import Session.Status exposing (Status(..))
import Utils.App as App
import Utils.OneOrMore as OneOrMore
import Version



-- MAIN


main =
  Browser.fullscreen
    { init = init
    , view = view
    , update = update
    , subscriptions = subscriptions
    , onNavigation = Just onNavigation
    }



-- MODEL


type alias Model =
  { session : Session.Data
  , route : Route.Route
  , page : Page
  }


type Page
  = Blank
  | Problem Problem.Suggestion
  | Diff Diff.Model
  | Docs Docs.Model



-- INIT


init : Browser.Env () -> ( Model, Cmd Msg )
init env =
  check (Model Session.empty (Route.fromUrl env.url) Blank)



-- SUBSCRIPTIONS


subscriptions : Model -> Sub Msg
subscriptions model =
  Sub.none



-- NAVIGATION


onNavigation : Browser.Url -> Msg
onNavigation url =
  Goto (Route.fromUrl url)



-- UPDATE


type Msg
  = Push Route.Route
  | Goto Route.Route
  | SessionMsg Session.Msg
  | DocsMsg Docs.Msg


update : Msg -> Model -> ( Model, Cmd Msg )
update message model =
  case message of
    Push route ->
      ( model
      , History.push (Route.toUrl route)
      )

    Goto route ->
      check { model | route = route }

    SessionMsg msg ->
      check { model | session = Session.update msg model.session }

    DocsMsg msg ->
      case model.page of
        Docs docsModel ->
          let
            (newDocsModel, cmds) =
               Docs.update msg docsModel
          in
          ( { model | page = Docs newDocsModel }, cmds )

        _ ->
          ( model, Cmd.none )



-- ROUTING


check : Model -> ( Model, Cmd Msg )
check model =
  let
    goto page =
      ( { model | page = page }, Cmd.none )
  in
  case model.route of
    Route.Home ->
      goto Blank

    Route.User name ->
      goto Blank

    Route.Package user project ->
      let
        toPage releases =
          Diff (Diff.Model user project (OneOrMore.toList releases))
      in
      onSuccess model <|
        Query.map toPage (Session.releases user project)

    Route.Version user project version info ->
      let
        metadataQuery =
          Query.map
            (Docs.Metadata user project version info)
            (Query.maybe (Session.latestVersion user project))

        contentQuery =
          case info of
            Route.Readme ->
              Query.map2 Docs.Readme (Session.readme user project version) <|
                Query.map (Maybe.withDefault []) <|
                  Query.maybe (Session.allDocs user project version)

            Route.Module name _ ->
              Query.map
                (Tuple.apply (Docs.Module name))
                (Session.moduleDocs user project version name)
      in
      onSuccess model <| Query.map Docs <|
        Query.map3 Docs.Model metadataQuery contentQuery (Query.success "")

    Route.Guidelines ->
      goto Blank

    Route.DocsHelp ->
      goto Blank

    Route.NotFound url ->
      goto (Problem Problem.NoIdea)


onSuccess : Model -> Session.Query Page -> ( Model, Cmd Msg )
onSuccess model query =
  let
    (newSession, cmds, status) =
      Query.check model.session query

    newPage =
      case status of
        Failure error _ ->
          Problem (Problem.BadResource error)

        Loading ->
          model.page

        Success page ->
          page
      in
      ( { model | session = newSession, page = newPage }
      , Cmd.map SessionMsg cmds
      )



-- VIEW


view : Model -> Browser.View Msg
view model =
  { title =
      toTitle model.route
  , body =
      [ center "#eeeeee" [ lazy2 viewHeader model.session model.page ]
      , center "#60B5CC" [ lazy2 viewVersionWarning model.session model.page ]
      , lazy viewPage model.page
      , viewFooter
      ]
  }


center : String -> List (Html msg) -> Html msg
center color kids =
  div [ style "background-color" color ] [ div [class "center"] kids ]


toTitle : Route.Route -> String
toTitle route =
  case route of
    Route.Home ->
      "Home"

    Route.User _ ->
      "User"

    Route.Package _ _ ->
      "Package"

    Route.Version _ _ _ _ ->
      "Version"

    Route.Guidelines ->
      "Guidelines"

    Route.DocsHelp ->
      "DocsHelp"

    Route.NotFound _ ->
      "NotFound"



-- VIEW PAGE


viewPage : Page -> Html Msg
viewPage page =
  let
    debody toMsg body =
      Html.map toMsg (App.viewBody body)
  in
  case page of
    Blank ->
      debody identity <| App.body [] []

    Problem suggestion ->
      debody Push <| Problem.view suggestion

    Docs docsModel ->
      debody DocsMsg <| Docs.view docsModel

    Diff diffModel ->
      debody Push <| Diff.view diffModel



-- VIEW ROUTE LINKS


viewHeader : Session.Data -> Page -> Html Msg
viewHeader sessionData page =
  h1 [ class "header" ] <| (::) (App.link Push Route.Home [] [ viewLogo ]) <|
    case page of
      Blank ->
        []

      Problem _ ->
        []

      Docs model ->
        let
          { user, project, version, latest, info } =
            model.metadata

          vsn =
            getLatestVersion version latest
        in
        List.intersperse slash <|
          [ userLink user
          , packageLink user project
          , versionLink user project vsn
          ]
          ++ moduleLink user project vsn info

      Diff { user, project } ->
        List.intersperse slash
          [ userLink user
          , packageLink user project
          ]


userLink : String -> Html Msg
userLink user =
  toLink (Route.User user) user


packageLink : String -> String -> Html Msg
packageLink user project =
  toLink (Route.Package user project) project


versionLink : String -> String -> Route.Version -> Html Msg
versionLink user project version =
  toLink
    (Route.Version user project version Route.Readme)
    (Route.vsnToString version)


moduleLink : String -> String -> Route.Version -> Route.VersionInfo -> List (Html Msg)
moduleLink user project version info =
  case info of
    Route.Readme ->
      []

    Route.Module moduleName maybeTag ->
      let
        route =
          Route.Version user project version (Route.Module moduleName maybeTag)
      in
      [ toLink route moduleName ]


getLatestVersion : Route.Version -> Maybe Version.Version -> Route.Version
getLatestVersion version maybeLatest =
  case version of
    Route.Exactly _ ->
      version

    Route.Latest ->
      case maybeLatest of
        Nothing ->
          version

        Just latest ->
          Route.Exactly latest


slash : Html msg
slash =
  span [ class "spacey-char" ] [ text "/" ]


toLink : Route.Route -> String -> Html Msg
toLink route words =
  App.link Push route [] [ text words ]



-- VIEW VERSION WARNINGS


viewVersionWarning : Session.Data -> Page -> Html Msg
viewVersionWarning session page =
  div [ class "header-underbar" ] <|
    case getNewerRoute session page of
      Nothing ->
        []

      Just (latestVersion, newerRoute) ->
        [ p [ class "version-warning" ]
            [ text "Warning! The latest version of this package is "
            , App.link Push newerRoute [] [ text (Version.toString latestVersion) ]
            ]
        ]


getNewerRoute : Session.Data -> Page -> Maybe (Version.Version, Route.Route)
getNewerRoute sessionData page =
  case page of
    Blank ->
      Nothing

    Problem _ ->
      Nothing

    Docs model ->
      case model.metadata.version of
        Route.Latest ->
          Nothing

        Route.Exactly version ->
          let
            { user, project, info, latest } =
              model.metadata

            checkLatest latestVersion =
              if version == latestVersion then
                Nothing
              else
                Just ( latestVersion, Route.Version user project Route.Latest info )
          in
          Maybe.andThen checkLatest latest

    Diff _ ->
      Nothing



-- VIEW FOOTER


viewFooter : Html msg
viewFooter =
  div [class "footer"]
    [ text "All code for this site is open source and written in Elm. "
    , a [ class "grey-link", href "https://github.com/elm-lang/package.elm-lang.org/" ] [ text "Check it out" ]
    , text "! — © 2012-present Evan Czaplicki"
    ]



-- VIEW LOGO


viewLogo : Html msg
viewLogo =
  div
    [ style "display" "-webkit-display"
    , style "display" "-ms-flexbox"
    , style "display" "flex"
    ]
    [ img
        [ src "/assets/elm_logo.svg"
        , style "height" "30px"
        , style "vertical-align" "bottom"
        , style "padding-right" "8px"
        ]
        []
    , div
        [ style "color" "black"
        ]
        [ div [ style "line-height" "20px" ] [ text "elm" ]
        , div
            [ style "line-height" "10px"
            , style "font-size" "0.5em"
            ]
            [ text "packages" ]
        ]
    ]
