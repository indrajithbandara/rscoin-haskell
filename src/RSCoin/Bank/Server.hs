{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections       #-}

-- | Server implementation for Bank

module RSCoin.Bank.Server
       ( serve
       ) where

import           Control.Concurrent             (MVar, newMVar)
import           Control.Concurrent.MVar.Lifted (modifyMVar_)
import           Control.Lens                   ((^.))
import           Control.Monad.Catch            (catch, throwM)
import           Control.Monad.Trans            (lift, liftIO)
import           Data.Acid.Advanced             (query', update')
import qualified Data.Map.Strict                as M
import           Formatting                     (int, sformat, (%))
import qualified Formatting                     as F (build)

import           Serokell.Util.Text             (format', formatSingle',
                                                 mapBuilder, show')

import           RSCoin.Bank.AcidState          (AddExplorer (..),
                                                 AddMintette (..),
                                                 GetAddresses (..),
                                                 GetEmission (..),
                                                 GetExplorersAndPeriods (..),
                                                 GetHBlock (..),
                                                 GetHBlocks (..), GetLogs (..),
                                                 GetMintettes (..),
                                                 GetPeriodId (..),
                                                 GetTransaction (..), State)
import           RSCoin.Bank.Error              (BankError)
import           RSCoin.Core                    (ActionLog,
                                                 AddressToTxStrategyMap,
                                                 Explorer, Explorers, HBlock,
                                                 Mintette, MintetteId,
                                                 Mintettes, PeriodId, PublicKey,
                                                 Signature, Transaction,
                                                 TransactionId, bankLoggerName,
                                                 logDebug, logError, logInfo,
                                                 verify)
import qualified RSCoin.Core.NodeConfig         as NC
import qualified RSCoin.Core.Protocol           as C
import qualified RSCoin.Timed                   as T

serve
    :: T.WorkMode m
    => State -> T.ThreadId -> (T.ThreadId -> m T.ThreadId) -> m ()
serve st workerThread restartWorkerAction = do
    threadIdMVar <- liftIO $ newMVar workerThread
    idr1 <- T.serverTypeRestriction0
    idr2 <- T.serverTypeRestriction0
    idr3 <- T.serverTypeRestriction1
    idr4 <- T.serverTypeRestriction1
    idr5 <- T.serverTypeRestriction1
    idr6 <- T.serverTypeRestriction2
    idr7 <- T.serverTypeRestriction3
    idr8 <- T.serverTypeRestriction0
    idr9 <- T.serverTypeRestriction0
    idr10 <- T.serverTypeRestriction3
    idr11 <- T.serverTypeRestriction3
    idr12 <- T.serverTypeRestriction1

    nodeCtx <- T.getNodeContext
    let bankPublicKey = nodeCtx ^. NC.bankPublicKey
    let bankPort      = nodeCtx ^. NC.bankPort

    C.serve
        bankPort
        [ C.method (C.RSCBank C.GetMintettes) $ idr1 $ serveGetMintettes st
        , C.method (C.RSCBank C.GetBlockchainHeight) $ idr2 $ serveGetHeight st
        , C.method (C.RSCBank C.GetHBlock) $ idr3 $ serveGetHBlock st
        , C.method (C.RSCBank C.GetTransaction) $ idr4 $ serveGetTransaction st
        , C.method (C.RSCBank C.FinishPeriod) $
          idr5 $ serveFinishPeriod st threadIdMVar restartWorkerAction bankPublicKey
        , C.method (C.RSCDump C.GetHBlocks) $ idr6 $ serveGetHBlocks st
        , C.method (C.RSCDump C.GetHBlocks) $ idr7 $ serveGetLogs st
        , C.method (C.RSCBank C.GetAddresses) $ idr8 $ serveGetAddresses st
        , C.method (C.RSCBank C.GetExplorers) $ idr9 $ serveGetExplorers st
        , C.method (C.RSCBank C.AddMintetteAdhoc) $
          idr10 $ serveAddMintetteAdhoc st bankPublicKey
        , C.method (C.RSCBank C.AddExplorerAdhoc) $
          idr11 $ serveAddExplorerAdhoc st bankPublicKey
        , C.method (C.RSCBank C.GetHBlockEmission) $
          idr12 $ serveGetHBlockEmission st]

toServer :: T.WorkMode m => m a -> T.ServerT m a
toServer action = lift $ action `catch` handler
  where
    handler (e :: BankError) = do
        logError bankLoggerName $ show' e
        throwM e

-- toServer' :: T.WorkMode m => IO a -> T.ServerT m a
-- toServer' = toServer . liftIO

serveGetAddresses :: T.WorkMode m => State -> T.ServerT m AddressToTxStrategyMap
serveGetAddresses st =
    toServer $
    do mts <- query' st GetAddresses
       logDebug bankLoggerName $ formatSingle' "Getting list of addresses: {}" $ mapBuilder $ M.toList mts
       return mts

serveGetMintettes :: T.WorkMode m => State -> T.ServerT m Mintettes
serveGetMintettes st =
    toServer $
    do mts <- query' st GetMintettes
       logDebug bankLoggerName $ formatSingle' "Getting list of mintettes: {}" mts
       return mts

serveGetHeight :: T.WorkMode m => State -> T.ServerT m PeriodId
serveGetHeight st =
    toServer $
    do pId <- query' st GetPeriodId
       logDebug bankLoggerName $ formatSingle' "Getting blockchain height: {}" pId
       return pId

serveGetHBlockEmission :: T.WorkMode m
               => State -> PeriodId -> T.ServerT m (Maybe (HBlock, Maybe TransactionId))
serveGetHBlockEmission st pId =
    toServer $
    do mBlock <- query' st (GetHBlock pId)
       emission <- query' st (GetEmission pId)
       logDebug bankLoggerName $
           format' "Getting higher-level block with periodId {} and emission {}: {}" (pId, emission, mBlock)
       return $ (,emission) <$> mBlock

serveGetHBlock :: T.WorkMode m
               => State -> PeriodId -> T.ServerT m (Maybe HBlock)
serveGetHBlock st pId =
    toServer $
    do mBlock <- query' st (GetHBlock pId)
       logDebug bankLoggerName $
           format' "Getting higher-level block with periodId {}: {}" (pId, mBlock)
       return mBlock

serveGetTransaction :: T.WorkMode m
                    => State -> TransactionId -> T.ServerT m (Maybe Transaction)
serveGetTransaction st tId =
    toServer $
    do t <- query' st (GetTransaction tId)
       logDebug bankLoggerName $
           format' "Getting transaction with id {}: {}" (tId, t)
       return t

-- !!! WARNING !!!
-- Usage of this function may accidentally lead to finishing period twice in a
-- row. But it is used only in benchmarks with infinite period so it is ok.
serveFinishPeriod
    :: T.WorkMode m
    => State
    -> MVar T.ThreadId
    -> (T.ThreadId -> m T.ThreadId)
    -> PublicKey
    -> Signature
    -> T.ServerT m ()
serveFinishPeriod st threadIdMVar restartAction bankPublicKey periodIdSignature = toServer $ do
    logInfo bankLoggerName "Forced finish of period was requested"

    modifyMVar_ threadIdMVar $ \workerThreadId -> do
        currentPeriodId <- query' st GetPeriodId
        if verify bankPublicKey periodIdSignature currentPeriodId then
            restartAction workerThreadId
        else do
            logError bankLoggerName $ sformat ("Incorrect signature for periodId=" % int) currentPeriodId
            return workerThreadId

serveAddMintetteAdhoc
    :: T.WorkMode m
    => State
    -> PublicKey
    -> Mintette
    -> PublicKey
    -> Signature
    -> T.ServerT m ()
serveAddMintetteAdhoc st bankPublicKey mintette pk proof =
    toServer $
    do logInfo bankLoggerName $
           sformat ("Adding mintette: " % F.build % " with pk " % F.build)
                   mintette pk
       if verify bankPublicKey proof (mintette,pk)
       then update' st (AddMintette mintette pk)
       else logError bankLoggerName $
                sformat ("Tried to add mintette " % F.build %
                         " with pk " % F.build % " with *failed* signature")
                        mintette pk

serveAddExplorerAdhoc
    :: T.WorkMode m
    => State
    -> PublicKey
    -> Explorer
    -> PeriodId
    -> Signature
    -> T.ServerT m ()
serveAddExplorerAdhoc st bankPublicKey explorer pId proof =
    toServer $
    do logInfo bankLoggerName $
           sformat ("Adding explorer " % F.build % " with pid " % int)
                   explorer pId
       if verify bankPublicKey proof (explorer, pId)
       then update' st (AddExplorer explorer pId)
       else logError bankLoggerName $
                sformat ("Tried to add explorer " % F.build %
                         " with pid" % int % " with *failed* signature")
                        explorer pId


-- Dumping Bank state

serveGetHBlocks :: T.WorkMode m
                => State -> PeriodId -> PeriodId -> T.ServerT m [HBlock]
serveGetHBlocks st from to =
    toServer $
    do blocks <- query' st $ GetHBlocks from to
       logDebug bankLoggerName $
           format' "Getting higher-level blocks between {} and {}"
           (from, to)
       return blocks

serveGetLogs :: T.WorkMode m
             => State -> MintetteId -> Int -> Int -> T.ServerT m (Maybe ActionLog)
serveGetLogs st m from to =
    toServer $
    do mLogs <- query' st (GetLogs m from to)
       logDebug bankLoggerName $
           format' "Getting action logs of mintette {} with range of entries {} to {}: {}" (m, from, to, mLogs)
       return mLogs

serveGetExplorers
    :: T.WorkMode m
    => State -> T.ServerT m Explorers
serveGetExplorers st = do
    curPeriod <- query' st GetPeriodId
    map fst . filter ((== curPeriod) . snd) <$>
        query' st GetExplorersAndPeriods
