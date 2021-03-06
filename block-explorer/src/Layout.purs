module App.Layout where

import Prelude                        (($), map, (<<<), pure, bind, not,
                                       (==), flip, (<>), (/=), otherwise, (+), (-))

import App.Routes                     (Path (..), addressUrl, txUrl,
                                       match) as R
import App.Connection                 (Action (..), WEBSOCKET,
                                       send, sendControl) as C
import App.Types                      (Address (..), ControlMsg (..),
                                       AddressInfoMsg (..),
                                       IncomingMsg (..),
                                       TransactionExtended,
                                       OutcomingMsg (..),
                                       Action (..), State, SearchQuery (..),
                                       PublicKey (..), ServerError (..), Hash (..),
                                       getTransactionId)
import App.CSS                        (veryLightGrey, styleSheet)
import App.View.Address               (view) as Address
import App.View.NotFound              (view) as NotFound
import App.View.BlockInfo             (view) as BlockInfo
import App.View.Transaction           (view) as Transaction
import App.View.Header                (view) as Header
import App.View.Alert                 (view) as Alert
import App.View.Footer                (view) as Footer

import Data.Maybe                     (Maybe(Nothing, Just), maybe,
                                       isNothing, isJust)

import Serokell.Data.Maybe            (unsafeFromJust)

import Data.Tuple                     (Tuple (..), snd)
import Data.Either                    (fromRight)
import Data.Generic                   (gShow)
import Data.Array                     (filter, head, reverse)
import Debug.Trace                    (traceAny)

import Pux                            (EffModel, noEffects, onlyEffects)
import Pux.Html                       (Html, div, style, text)
import Pux.Html.Attributes            (type_, id_, className)

import Pux.Router                     (navigateTo) as R
import Pux.CSS                        (style, backgroundColor) as CSS
import CSS.Render                     (renderedSheet, render)

import Control.Apply                  ((*>))
import Control.Alternative            ((<|>))
import Control.Applicative            (when, unless)

import DOM                            (DOM)
import Control.Monad.Eff.Console      (CONSOLE)
import Control.Monad.Eff.Class        (liftEff)

import Partial.Unsafe                 (unsafePartial)

txNum :: Int
txNum = 15

blocksNum :: Int
blocksNum = 5

txGlobalNum :: Int
txGlobalNum = 5

update :: Action -> State -> EffModel State Action (console :: CONSOLE, ws :: C.WEBSOCKET, dom :: DOM)
update (PageView route@R.Home) state =
    { state: state { route = route }
    , effects:
        [ onNewQueryDo do
            C.send socket' $ IMControl CMGetBlockchainHeight
            pure Nop
        ]
    }
  where
    socket' = unsafeFromJust state.socket
    -- TODO: update other `onNewQuery` with this function!
    onNewQueryDo action | state.route == route = pure Nop -- ignore
                        | otherwise = action
update (PageView route@(R.Address addr)) state =
    { state: state { route = route }
    , effects:
        [ onNewQueryDo do
            C.send socket' $ IMControl $ CMSetAddress addr
            pure Nop
        ]
    }
  where
    socket' = unsafeFromJust state.socket
    onNewQueryDo action | state.queryInfo == Just (SQAddress addr) = pure Nop -- ignore
                        | otherwise = action
update (PageView route@(R.Transaction tId)) state =
    { state: state { route = route, queryInfo = map SQTransaction getTransaction }
    , effects:
        [ onNewQueryDo do
            when (isNothing getTransaction) $
                C.send socket' $ IMControl $ CMGetTransaction tId
            pure Nop
        ]
    }
  where
    socket' = unsafeFromJust state.socket
    getTransaction =
        queryGetTx state.queryInfo
        <|>
        head (filter ((==) tId <<< getTransactionId) state.transactions)
    queryGetTx (Just (SQTransaction tx))
        | getTransactionId tx == tId = Just tx
    queryGetTx _ = Nothing
    onNewQueryDo action | isJust getTransaction = pure Nop -- ignore
                        | otherwise = action
update (PageView route) state = noEffects $ state { route = route }
update (SocketAction (C.ReceivedData msg)) state = traceAny (gShow msg) $
    \_ -> case unsafePartial $ fromRight msg of
        OMBalance addr pId coinsMap ->
            { state: state { balance = Just coinsMap, periodId = pId, queryInfo = Just (SQAddress addr) }
            , effects:
                [ do
                    C.send socket' <<< IMAddrInfo <<< AIGetTransactions $ Tuple 0 txNum
                    let expectedUrl = R.addressUrl addr
                    unless (state.route == R.match expectedUrl) $
                        liftEff $ R.navigateTo expectedUrl
                    pure Nop
                ]
            }
        OMAddrTransactions addr _ arr ->
            noEffects $ state { transactions = map snd arr, queryInfo = Just (SQAddress addr) }
        OMTransaction _ tx ->
            { state: state { queryInfo = Just $ SQTransaction tx }
            , effects:
                [ do
                    let expectedUrl = R.txUrl $ getTransactionId tx
                    unless (state.route == R.match expectedUrl) $
                        liftEff $ R.navigateTo expectedUrl
                    pure Nop
                ]
            }
        OMTxNumber addr _ txNum ->
            noEffects $ state { txNumber = Just txNum, queryInfo = Just (SQAddress addr) }
        OMBlocksOverview blocks ->
            noEffects $ state { blocks = reverse $ map snd blocks }
        OMTransactionsGlobal _ txs ->
            noEffects $ state { transactions = map snd txs }
        OMBlockchainHeight pId ->
            onlyEffects state $
                [ do
                    C.send socket' $ IMControl $ CMGetBlocksOverview $ Tuple (pId - blocksNum) (pId + 1)
                    C.send socket' $ IMControl $ CMGetTransactionsGlobal $ Tuple 0 txGlobalNum
                    pure Nop
                ]
        OMError (ParseError e) ->
            noEffects $ state { error = Just $ "ParseError: " <> e.peTypeName <> " : " <> e.peError }
        OMError (NotFound e) ->
            noEffects $ state { error = Just $ "NotFound: " <> e }
        OMError (LogicError e) ->
            noEffects $ state { error = Just $ "LogicError: " <> e }
        _ -> noEffects state
  where
    socket' = unsafeFromJust state.socket
update (SocketAction _) state = noEffects state
update (SearchQueryChange sq) state = noEffects $ state { searchQuery = sq }
update SearchButton state =
    onlyEffects state $
        [ do
            C.send socket' $ IMControl $ CMSmart state.searchQuery
            pure Nop
        ]
  where
    socket' = unsafeFromJust state.socket
update DismissError state = noEffects $ state { error = Nothing }
update ColorToggle state =
    noEffects $ state { colors = not state.colors }
update (LanguageSet l) state =
    noEffects $ state { language = l }
update Nop state = noEffects state

-- TODO: make safe version of bootstrap like
-- https://github.com/slamdata/purescript-halogen-bootstrap/blob/master/src/Halogen/Themes/Bootstrap3.purs
view :: State -> Html Action
view state =
    div
        [ className "very-light-grey-background max-height" ]
        [-- style
         --   [ type_ "text/css" ]
         --   [ text $ unsafePartial $ fromJust $ renderedSheet $ render styleSheet ]
          Header.view state
        , Alert.view state
        , div
            [ className "container-fluid"
            , id_ "page-content"
            ]
            [ case state.route of
                R.Home -> BlockInfo.view state
                R.Address addr ->
                    let
                        queryGetAddr (Just (SQAddress addr)) = Just addr
                        queryGetAddr _ = Nothing
                    in  maybe (NotFound.view state) (flip Address.view state) $ queryGetAddr state.queryInfo
                R.Transaction tId ->
                    let
                        queryGetTx (Just (SQTransaction tx)) = Just tx
                        queryGetTx _ = Nothing
                    in  maybe (NotFound.view state) (flip Transaction.view state) $ queryGetTx state.queryInfo
                R.NotFound -> NotFound.view state
            ]
        , Footer.view state
        ]
