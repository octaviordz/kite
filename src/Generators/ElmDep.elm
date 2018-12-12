port module Generators.ElmDep exposing (ElmFileContentAccumulator, Model, Msg(..), StateVizData(..), finishedDownloadingWith, getPathsOfElmFiles, initialModel, stateVizData, toGraphFile, update)

import Char
import Colors
import Dict exposing (Dict)
import Graph exposing (Edge, Node)
import Graph.Layout
import GraphFile as GF exposing (EdgeProperties, GraphFile, MyGraph, VertexId, VertexProperties)
import Http
import Json.Decode as JD exposing (Decoder, Value)
import Parser exposing ((|.), (|=), Parser)
import Set exposing (Set)


type alias Model =
    { githubUserName : String
    , repositoryName : String
    , state : State
    }


type State
    = Idle
    | Downloading ElmFileContentAccumulator
    | DownloadFinished (List ElmFile)
    | DownloadError String


type alias ElmFileContentAccumulator =
    { pathsToDownload : List String
    , downloaded : List ElmFile
    }


type ElmFile
    = ElmFile
        { moduleName : String
        , dependencies : List String
        , loc : Int
        }


type Msg
    = GotPathsOfElmFiles (Result Http.Error (List String))
    | GotRawElmFile (Result Http.Error String)
    | ChangeGithubUserName String
    | ChangeRepositoryName String


initialModel : Model
initialModel =
    { githubUserName = "erkal"
    , repositoryName = "kite"
    , state = DownloadFinished []
    }


finishedDownloadingWith : Model -> Maybe (List ElmFile)
finishedDownloadingWith m =
    case m.state of
        DownloadFinished l ->
            Just l

        _ ->
            Nothing


fromRawtoElmFile : String -> ElmFile
fromRawtoElmFile raw =
    let
        lines =
            String.lines raw

        moduleNameParser : Parser String
        moduleNameParser =
            Parser.variable
                { start = Char.isUpper
                , inner = \c -> Char.isAlphaNum c || c == '_' || c == '.'
                , reserved = Set.empty
                }
    in
    ElmFile
        { moduleName =
            lines
                |> List.filterMap
                    (Parser.run
                        (Parser.oneOf
                            [ Parser.succeed identity
                                |. Parser.keyword "module"
                            , Parser.succeed identity
                                |. Parser.keyword "port"
                                |. Parser.spaces
                                |. Parser.keyword "module"
                            ]
                            |. Parser.spaces
                            |= moduleNameParser
                        )
                        >> Result.toMaybe
                    )
                |> List.head
                |> Maybe.withDefault "ERROR"
        , dependencies =
            lines
                |> List.filterMap
                    (Parser.run
                        (Parser.succeed identity
                            |. Parser.keyword "import"
                            |. Parser.spaces
                            |= moduleNameParser
                        )
                        >> Result.toMaybe
                    )
        , loc = List.length lines
        }


getPathsOfElmFiles : Model -> Cmd Msg
getPathsOfElmFiles m =
    Http.get
        { url =
            "https://api.github.com/repos/"
                ++ m.githubUserName
                ++ "/"
                ++ m.repositoryName
                ++ "/git/trees/master?recursive=1"
        , expect = Http.expectJson GotPathsOfElmFiles pathsOfElmFilesDecoder
        }


pathsOfElmFilesDecoder : Decoder (List String)
pathsOfElmFilesDecoder =
    JD.field "tree" (JD.list (JD.field "path" JD.string))
        |> JD.map (List.filter (String.endsWith ".elm"))


update : Msg -> Model -> ( Model, Cmd Msg )
update msg m =
    let
        withState newState =
            { m | state = newState }
    in
    case msg of
        ChangeGithubUserName str ->
            ( { m | githubUserName = str, state = Idle }, Cmd.none )

        ChangeRepositoryName str ->
            ( { m | repositoryName = str, state = Idle }, Cmd.none )

        GotPathsOfElmFiles httpResult ->
            case m.state of
                Downloading _ ->
                    ( m, Cmd.none )

                _ ->
                    case httpResult of
                        Ok (p :: ps) ->
                            ( withState
                                (Downloading (ElmFileContentAccumulator ps []))
                            , Http.get
                                { url =
                                    "https://raw.githubusercontent.com/"
                                        ++ m.githubUserName
                                        ++ "/"
                                        ++ m.repositoryName
                                        ++ "/master/"
                                        ++ p
                                , expect = Http.expectString GotRawElmFile
                                }
                            )

                        Ok [] ->
                            ( withState
                                (DownloadError "No Elm Files have been found.")
                            , Cmd.none
                            )

                        _ ->
                            ( withState
                                (DownloadError "Couldn't connect to github.")
                            , Cmd.none
                            )

        GotRawElmFile httpResult ->
            case m.state of
                Downloading { pathsToDownload, downloaded } ->
                    case httpResult of
                        Ok raw ->
                            case pathsToDownload of
                                p :: ps ->
                                    ( withState
                                        (Downloading
                                            (ElmFileContentAccumulator ps
                                                (fromRawtoElmFile raw :: downloaded)
                                            )
                                        )
                                    , Http.get
                                        { url =
                                            "https://raw.githubusercontent.com/"
                                                ++ m.githubUserName
                                                ++ "/"
                                                ++ m.repositoryName
                                                ++ "/master/"
                                                ++ p
                                        , expect =
                                            Http.expectString GotRawElmFile
                                        }
                                    )

                                [] ->
                                    ( withState
                                        (DownloadFinished
                                            (fromRawtoElmFile raw :: downloaded)
                                        )
                                    , Cmd.none
                                    )

                        _ ->
                            ( withState (DownloadError "")
                            , Cmd.none
                            )

                _ ->
                    ( m
                    , Cmd.none
                    )


toGraphFile : List ElmFile -> GraphFile
toGraphFile l =
    let
        dVP =
            GF.defaultVertexProp

        dEP =
            GF.defaultEdgeProp

        idDict : Dict String VertexId
        idDict =
            l
                |> List.indexedMap
                    (\i (ElmFile { moduleName }) -> ( moduleName, i + 1 ))
                |> Dict.fromList

        safeGetId : String -> VertexId
        safeGetId moduleName =
            idDict |> Dict.get moduleName |> Maybe.withDefault 0

        handleElmFile (ElmFile { moduleName, dependencies, loc }) =
            ( Node (safeGetId moduleName)
                { dVP
                    | label = Just moduleName
                    , labelAbove = True
                    , radius = 0.5 * sqrt (toFloat loc)
                    , fixed = moduleName == "Main"
                }
            , dependencies
                |> List.filterMap
                    (\importedModule ->
                        case Dict.get importedModule idDict of
                            Just j ->
                                Just (Edge (safeGetId moduleName) j dEP)

                            Nothing ->
                                Nothing
                    )
            )

        nodesWithOutgoingNeighbours : List ( Node VertexProperties, List (Edge EdgeProperties) )
        nodesWithOutgoingNeighbours =
            List.map handleElmFile l

        nodes =
            nodesWithOutgoingNeighbours |> List.map Tuple.first

        edges =
            nodesWithOutgoingNeighbours |> List.map Tuple.second |> List.concat

        graph =
            Graph.fromNodesAndEdges nodes edges
                |> Graph.Layout.circular
                    { center = ( 300, 300 ), radius = 250 }
    in
    GF.setGraph graph GF.default


type StateVizData
    = WaitingForUserInput
    | Downloaded (List String)
    | Error String


stateVizData : Model -> StateVizData
stateVizData m =
    let
        getNames =
            List.map (\(ElmFile { moduleName }) -> moduleName)
    in
    case m.state of
        Idle ->
            WaitingForUserInput

        Downloading { pathsToDownload, downloaded } ->
            Downloaded (List.reverse (getNames downloaded))

        DownloadFinished listOfElmFiles ->
            Downloaded (List.reverse (getNames listOfElmFiles))

        DownloadError str ->
            Error str