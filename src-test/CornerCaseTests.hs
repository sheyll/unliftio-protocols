{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

-- | Test race conditions
module CornerCaseTests (test) where

import Control.Exception
  ( BlockedIndefinitelyOnMVar (BlockedIndefinitelyOnMVar),
  )
import Data.Semigroup (Any (Any, getAny), Semigroup (stimes))
import Protocol.Command
  ( Command,
    CommandError (BlockingCommandTimedOut),
    Message (Blocking),
    ReturnType (Return),
    call,
  )
import Protocol.Command.CallId
  ( CallId (MkCallId),
  )
import qualified Protocol.Command.CallId as CallId
import Protocol.MessageBox.Class
  ( Input,
    IsInput (deliver),
    IsMessageBox (newInput, receive),
    IsMessageBoxFactory (..),
    handleMessage,
    receiveAfter,
  )
import qualified Protocol.MessageBox.Limited as B
import qualified Protocol.MessageBox.Unlimited as U
import RIO
  ( HasCallStack,
    runRIO,
    threadDelay,
  )
import System.Mem (performMajorGC, performMinorGC)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit
  ( assertBool,
    assertEqual,
    assertFailure,
    testCase,
  )
import UnliftIO
  ( MVar,
    MonadIO (..),
    MonadUnliftIO,
    concurrently,
    newEmptyMVar,
    putMVar,
    takeMVar,
    timeout,
    try,
  )
import UnliftIO.Concurrent (forkIO, yield)

test :: TestTree
test =
  testGroup
    "CornerCaseTests"
    [ testGroup
        "waiting for messages from a dead process"
        [ testCase "When using the Unlimited Message BlockingBox, an exception is thrown" $
            try @_ @BlockedIndefinitelyOnMVar
              (waitForMessageFromDeadProcess U.UnlimitedMessageBox)
              >>= either
                ( assertEqual
                    "wrong exception thrown: "
                    (show BlockedIndefinitelyOnMVar)
                    . show
                )
                (const (assertFailure "Exception expected!")),
          testCase "When using the Limited Message BlockingBox, the test will timeout" $
            waitForMessageFromDeadProcess (B.BlockingBoxLimit B.MessageLimit_16)
              >>= assertEqual "unexpected return value: " SecondReceiveTimedOut
        ],
      testGroup
        "sending messages to a dead process"
        [ testCase "When using the Unlimited Message BlockingBox, sending messages succeeds" $
            sendMessagesToDeadProcess U.UnlimitedMessageBox
              >>= assertEqual "unexpected result: " SomeMoreMessagesSent,
          testCase "When using the Blocking Limited Message BlockingBox, sending messages eventually blocks and times out" $
            sendMessagesToDeadProcess (B.BlockingBoxLimit B.MessageLimit_16)
              >>= assertEqual "unexpected result: " SendingMoreMessagesTimedOut
        ],
      testGroup
        "Command"
        [ testGroup
            "waiting for a call reply after the server died"
            [ testCase "When using the Unlimited Message BlockingBox, BlockingCommandTimedOut is returned" $
                waitForCallReplyFromDeadServer U.UnlimitedMessageBox
                  >>= assertEqual
                    "unexpected result: "
                    (CallFailed (BlockingCommandTimedOut (MkCallId 1))),
              testCase "When using the Limited Message BlockingBox, BlockingCommandTimedOut is returned" $
                waitForCallReplyFromDeadServer (B.BlockingBoxLimit B.MessageLimit_16)
                  >>= assertEqual
                    "unexpected result: "
                    (CallFailed (BlockingCommandTimedOut (MkCallId 1)))
            ]
        ]
    ]

data WaitForMessageFromDeadProcessResult
  = SecondReceiveReturnedNothing
  | SecondReceiveTimedOut
  | SecondReceiveUnexpectedSuccess
  deriving stock (Show, Eq)

waitForMessageFromDeadProcess ::
  (HasCallStack, IsMessageBoxFactory cfg) =>
  cfg ->
  IO WaitForMessageFromDeadProcessResult
waitForMessageFromDeadProcess outputCfg =
  do
    firstMessageSent <- newEmptyMVar
    let msg1 = Just 42
    output <- newMessageBox outputCfg
    _ <- forkIO $ do
      input <- newInput output
      deliver input msg1 >>= assertBool "first message not sent!"
      putMVar firstMessageSent ()
    takeMVar firstMessageSent
    receive output
      >>= maybe
        (assertFailure "failed to receive first message")
        (assertEqual "invalid first message received!" msg1)
    threadDelay 10_000
    liftIO performMinorGC
    liftIO performMajorGC
    threadDelay 10_000
    receiveAfter output 200_000 (return (Just Nothing))
      >>= maybe
        (return SecondReceiveReturnedNothing ) 
        ( \case
            Nothing -> return SecondReceiveTimedOut
            (Just _) -> return SecondReceiveUnexpectedSuccess)
        -- ( maybe
        --     (return SecondReceiveTimedOut)
        --     ( \r -> do
        --         liftIO (assertEqual "unexpected second message received!" msg1 r)
        --         return SecondReceiveUnexpectedSuccess
        --     )
        -- )

data SendMessageToDeadProcessResult
  = NoMoreMessagesSent
  | SomeMoreMessagesSent
  | SendingMoreMessagesTimedOut
  deriving stock (Show, Eq)

sendMessagesToDeadProcess ::
  (HasCallStack, IsMessageBoxFactory cfg) =>
  cfg ->
  IO SendMessageToDeadProcessResult
sendMessagesToDeadProcess outputCfg =
  do
    ready <- newEmptyMVar
    firstMessageSent <- newEmptyMVar
    done <- newEmptyMVar
    let msg1 = 42

    _receiver <- forkIO $ do
      output <- newMessageBox outputCfg
      input <- newInput output
      putMVar ready input
      takeMVar firstMessageSent
      receive output >>= putMVar done

    input <- takeMVar ready
    deliver input msg1 >>= assertBool "first message not sent!"
    putMVar firstMessageSent ()
    takeMVar done >>= assertEqual "first message invalid" (Just msg1)
    threadDelay 10_000
    liftIO performMinorGC
    liftIO performMajorGC
    threadDelay 10_000

    timeout
      1_000_000
      (stimes 100 (Any <$> deliver input msg1))
      >>= maybe
        (return SendingMoreMessagesTimedOut)
        ( \r ->
            return $
              if getAny r
                then SomeMoreMessagesSent
                else NoMoreMessagesSent
        )

-- ------------------------------------------------------------

data WaitForCallReplyFromDeadServerResult
  = WaitForCallReplyFromDeadServerResult
  | CallFailed CommandError
  | WaitForCallReplyFromDeadServerNoResult
  deriving stock (Show, Eq)

waitForCallReplyFromDeadServer ::
  (IsMessageBoxFactory cfg) =>
  cfg ->
  IO WaitForCallReplyFromDeadServerResult
waitForCallReplyFromDeadServer outputCfg =
  do
    ready <- newEmptyMVar
    (cr, sr) <-
      concurrently
        (waitForCallReplyFromDeadServerClient ready)
        (waitForCallReplyFromDeadServerServer outputCfg ready)
    assertEqual "unexpected server process exit: " () sr
    return cr

waitForCallReplyFromDeadServerClient ::
  (MonadIO m, IsInput o) =>
  MVar (o (Message TestServer)) ->
  m WaitForCallReplyFromDeadServerResult
waitForCallReplyFromDeadServerClient ready = do
  input <- takeMVar ready
  cic <- CallId.newCallIdCounter
  runRIO cic (threadDelay 1_000 >> call input TestCall 100_000)
    >>= either
      (return . CallFailed)
      (const (return WaitForCallReplyFromDeadServerResult))

waitForCallReplyFromDeadServerServer ::
  (IsMessageBoxFactory cfg) =>
  cfg ->
  MVar (Input (MessageBox cfg) (Message TestServer)) ->
  IO ()
waitForCallReplyFromDeadServerServer outputCfg ready = do
  output <- newMessageBox outputCfg
  input <- newInput output
  putMVar ready input
  -- threadDelay 1_000
  handleLoop output
  where
    handleLoop ::
      (MonadUnliftIO m, IsMessageBox output) =>
      output (Message TestServer) ->
      m ()
    handleLoop output =
      handleMessage
        output
        ( \case
            Blocking TestCall _r -> do
              _ <- forkIO $ do
                threadDelay 10_000
                liftIO performMinorGC
                liftIO performMajorGC
              return ()
        )
        >>= maybe
          (yield >> handleLoop output)
          return

data TestServer

data instance Command TestServer _ where
  TestCall :: Command TestServer ( 'Return ())

deriving stock instance Show (Command TestServer ( 'Return ()))

-- Simple server loop

-- data ServerState protocol model = MkServerState
--   { state :: model,
--     self :: Input protocol
--   }

-- data ServerLoopResult model where
--   Continue :: ServerLoopResult model
--   ContinueWith :: model -> ServerLoopResult model
--   StopServerLoop :: ServerLoopResult model

-- type InitCallback protocol model err m =
--   ServerState protocol () -> m (Either err model)

-- type UpdateCallback protocol model m =
--   ServerState protocol model -> Message protocol -> m (ServerLoopResult model)

-- type CleanupCallback protocol model m =
--   ServerState protocol model -> m ()

-- forkServer ::
--   InitCallback protocol model initErrror m ->
--   UpdateCallback protocol model m ->
--   CleanupCallback protocol model m ->
--   m (Either initError (Input protocol))
-- forkServer = undefined

-- data Counter

-- data instance Command Counter t where
--   Incr :: Command Counter FireAndForget
--   Set :: Int -> Command Counter FireAndForget
--   Get :: Command Counter (Return Int)
