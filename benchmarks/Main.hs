{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE StrictData #-}

module Main (main) where

import Control.Monad ( replicateM, void )
import Criterion.Main (defaultMain)
import Criterion.Types
  ( bench,
    bgroup,
    nfAppIO,
  )
import Data.Semigroup (Semigroup (stimes))
import Protocol.MessageBox
  (trySendAndWaitForever,  InBox,
    OutBox,
    createInBox,
    createOutBoxForInbox,
    receive,
  )
import UnliftIO ( conc, runConc, Conc, MonadUnliftIO )

main =
  defaultMain
    [ bgroup
        "MessageBox: n -> m"
        [let 
            noMessages = 10_000
          in
          bgroup
            ("sending " ++ show noMessages ++ " messages")
            [ bench
                "1 sender -> 1 receiver"
                ( nfAppIO nToM (1, noMessages, 1)
                ),
              bench
                "1 sender -> 100 receivers"
                ( nfAppIO nToM (1, noMessages, 100)
                ),
              bench
                "1 sender -> 1000 receivers"
                ( nfAppIO nToM (1, noMessages, 1000)
                ),
              bench
                "1 sender -> 10000 receivers"
                ( nfAppIO nToM (1, noMessages, 10000)
                ),
              bench
                "1 sender -> 1 receiver"
                ( nfAppIO nToM (1, noMessages, 1)
                ),
              -- multiple senders
              bench
                "10 senders -> 100 receivers"
                ( nfAppIO nToM (10, noMessages, 100)
                ),
              bench
                "100 senders -> 10 receivers"
                ( nfAppIO nToM (100, noMessages, 100)
                ),
              bench
                "1000 senders -> 1 receiver"
                ( nfAppIO nToM (1000, noMessages, 1)
                ),
              bench
                "10000 senders -> 1 receiver"
                ( nfAppIO nToM (10000, noMessages, 1)
                )
            ]
        ]
    ]

send :: MonadUnliftIO m => OutBox a -> a -> m ()
send !o = void . trySendAndWaitForever o
    

-- sendWithTimeout :: MonadUnliftIO m => Int -> OutBox a -> a -> m ()
-- sendWithTimeout !to !o =
--   trySendAndWait to o
--     >=> ( \case
--             Left e -> void (error (show e))
--             _ -> return ()
--         )

nToM ::
  MonadUnliftIO m => (Int, Int, Int) -> m ()
nToM =
  senderSendsMessagesToReceivers send --(sendWithTimeout 1000000000)

senderSendsMessagesToReceivers ::
  MonadUnliftIO m => TrySendFun m -> (Int, Int, Int) -> m ()
senderSendsMessagesToReceivers trySendImpl (!nSenders, !nMsgsTotal, !nReceivers) = do
  allThreads <-
    do
      let nMsgsPerReceiver = nMsgsTotal `div` nReceivers
      (receiverThreads, receiverOutBoxes) <- startReceivers nMsgsPerReceiver nReceivers
      let nMsgsPerSender = nMsgsPerReceiver `div` nSenders
      let !senderThreads = stimes nSenders (conc (senderLoop trySendImpl receiverOutBoxes nMsgsPerSender))
      return (senderThreads <> receiverThreads)
  runConc allThreads

type TrySendFun f = (forall x. OutBox x -> x -> f ())

senderLoop :: MonadUnliftIO f => TrySendFun f -> [OutBox TestMsg] -> Int -> f ()
senderLoop trySendImpl !rs !noMsgs =
  mapM_
    (uncurry trySendImpl)
    ((,) <$> rs <*> replicate noMsgs (MkTestMsg False))

newtype TestMsg = MkTestMsg {_poison :: Bool}

startReceivers ::
  MonadUnliftIO m =>
  Int ->
  Int ->
  m (Conc m (), [OutBox TestMsg])
startReceivers nMsgs nReceivers = do
  inBoxes <- replicateM nReceivers (createInBox 128)
  let receivers = foldMap (conc . receiverLoop nMsgs) inBoxes
  outBoxes <- traverse createOutBoxForInbox inBoxes
  return (receivers, outBoxes)

receiverLoop :: MonadUnliftIO m => Int -> InBox TestMsg -> m ()
receiverLoop workLeft inBox
  | workLeft < 1 = pure ()
  | otherwise = do 
      _ <- receive inBox 
      receiverLoop (workLeft - 1) inBox
