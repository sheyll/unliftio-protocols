{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE StrictData #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

-- | Basic benchmark for the Command api.
-- In this benchmark n producers `Donate` books to the book store,
-- which are processed by m consumers
module BookStoreBenchmark (benchmark) where

import Control.Monad (replicateM, zipWithM_)
import Criterion.Types
  ( bench,
    bgroup,
    nfAppIO,
  )
import Data.Semigroup (Semigroup (stimes), sconcat)
import Protocol.BoundedMessageBox (InBoxConfig (BoundedMessageBox))
import Protocol.Command as Command
  ( CallId,
    Command,
    Message (Blocking, NonBlocking),
    ReturnType (FireAndForget, Return),
    call,
    cast,
    handleMessage,
    replyTo,
  )
import Protocol.Fresh
  ( CounterVar,
    HasCounterVar (..),
    newCounterVar,
  )
import Protocol.MessageBoxClass (IsMessageBox (..))
import Protocol.UnboundedMessageBox (InBoxConfig (UnboundedMessageBox))
import RIO
  ( MonadIO (liftIO),
    MonadUnliftIO,
    conc,
    runConc,
    runRIO,
    traverse_,
    unless,
    when,
  )

mkExampleBook :: Int -> Book
mkExampleBook !i =
  MkBook
    ( "The not so very very very very very very very very very very very very very very very very very very very very very very very very " ++ show i,
      "large",
      "Laoreet non curabitur gravida arcu ac tortor dignissim convallis aenean. Placerat in egestas erat imperdiet sed euismod nisi porta. Id consectetur purus ut faucibus pulvinar. Nulla porttitor massa id neque aliquam vestibulum morbi blandit. Risus nullam eget felis eget nunc lobortis. Et malesuada fames ac turpis. Pellentesque nec nam aliquam sem. Tellus rutrum tellus pellentesque eu tincidunt tortor aliquam nulla facilisi. Aliquam id diam maecenas ultricies mi. Eu lobortis elementum nibh tellus molestie nunc non." ++ show i,
      ( "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum.",
        "Dolor sit amet consectetur adipiscing elit ut aliquam. Integer eget aliquet nibh praesent tristique magna. Nulla facilisi morbi tempus iaculis. Cursus mattis molestie a iaculis at erat pellentesque adipiscing. Posuere sollicitudin aliquam ultrices sagittis orci a scelerisque purus semper. Amet venenatis urna cursus eget nunc scelerisque viverra. Fermentum odio eu feugiat pretium nibh ipsum consequat nisl. Vitae auctor eu augue ut lectus arcu bibendum at varius. Quis commodo odio aenean sed adipiscing diam donec adipiscing tristique. Dictumst quisque sagittis purus sit amet volutpat consequat mauris nunc. Integer vitae justo eget magna fermentum iaculis eu non diam. Et egestas quis ipsum suspendisse ultrices gravida dictum fusce ut. Senectus et netus et malesuada. In arcu cursus euismod quis viverra. Fames ac turpis egestas integer. Tortor condimentum lacinia quis vel eros donec ac odio. Interdum velit laoreet id donec ultrices tincidunt arcu non. Aenean et tortor at risus viverra adipiscing at.",
        even i,
        123423421111111111111111111123234 * toInteger i
      )
    )

newtype Book = MkBook ([Char], [Char], [Char], ([Char], [Char], Bool, Integer))
  deriving stock (Show, Eq, Ord)

data BookStore

data instance Command BookStore _ where
  Donate :: Book -> Command BookStore 'FireAndForget
  GetBooks :: Command BookStore ( 'Return [Book])

deriving stock instance Eq (Command BookStore 'FireAndForget)

deriving stock instance Show (Command BookStore 'FireAndForget)

deriving stock instance Eq (Command BookStore ( 'Return [Book]))

deriving stock instance Show (Command BookStore ( 'Return [Book]))

newtype BookStoreEnv = MkBookStoreEnv
  {_fresh :: CounterVar CallId}

instance HasCounterVar CallId BookStoreEnv where
  getCounterVar MkBookStoreEnv {_fresh} = _fresh
  putCounterVar newFresh MkBookStoreEnv {_fresh} = MkBookStoreEnv {_fresh = newFresh}

onlyCasts ::
  (MonadUnliftIO m, IsMessageBox inbox outbox) =>
  (Int -> Book) ->
  InBoxConfig inbox ->
  (Int, Int, Int) ->
  m ()
onlyCasts !msgGen !impl (!nP, !nMTotal, !nC) = do
  freshCounter <- newCounterVar
  runRIO (MkBookStoreEnv {_fresh = freshCounter}) $ do
    bookStoreInBox <- newInBox impl
    bookStoreOutBox <- newOutBox bookStoreInBox
    let producer 0 = pure ()
        producer workLeft = do
          ok <- cast bookStoreOutBox (Donate $ msgGen 1)
          unless ok (error "cast failed!")
          producer (workLeft - 1)
    let consumer 0 = pure ()
        consumer workLeft =
          let handler =
                handleMessage bookStoreInBox $
                  \case
                    NonBlocking _actual -> do
                      return Nothing
                    a -> do
                      liftIO $ putStrLn "blocking case called"
                      pure (Just ("did not expect message: " <> show a))
           in handler
                >>= maybe
                  (error "HandleMessage failed!")
                  ( maybe
                      (consumer (workLeft - 1))
                      error
                  )
    let perProducerWork = nMTotal `div` nP -- books to donate per producer
        perConsumerWork = nMTotal `div` nC -- books to receive per consumer
    let consumers = stimes nC (conc $ consumer perConsumerWork)
    let producers = stimes nP (conc $ producer perProducerWork)
    runConc (producers <> consumers)

castsAndCalls ::
  (MonadUnliftIO m, IsMessageBox inbox outbox) =>
  (Int -> Book) ->
  InBoxConfig inbox ->
  ((Int, Int), Int, (Int, Int)) ->
  m ()
castsAndCalls !msgGen !impl ((!nDonors, !nDonationsPerStore), !nStores, (!nCustomers, !nRequestsPerStore)) = do
  freshCounter <- newCounterVar
  runRIO (MkBookStoreEnv {_fresh = freshCounter}) $ do
    let -- donate nDonationsPerStore books to all bookStores
        donor !bookStores !producerId =
          let books !storeId =
                msgGen
                  . (storeId +)
                  . (nStores *)
                  . ((nDonationsPerStore * producerId) +)
                  <$> [0 .. nDonationsPerStore - 1]
              donateIt (!storeId, !bookStoreOutBox) =
                traverse_
                  ( \ !b ->
                      do
                        ok <- cast bookStoreOutBox (Donate b)
                        unless ok (error "cast failed!")
                  )
                  (books storeId)
           in conc (traverse_ donateIt (zip [0 ..] bookStores))
    let -- ask all bookstores nRequestsPerStore times for their books
        customer !stores = conc (go nRequestsPerStore)
          where
            go 0 = return ()
            go !workLeft = 
              let 
                getBooks !store  =
                  call store GetBooks 5_000_000
                    >>= either
                      (error . ("get books failed: " ++) . show)
                      (const (pure ()))
              in 
                traverse_ getBooks stores 
                >> go (workLeft - 1)

    let -- handle nMessagesToHandle requests
        bookStore nMessagesToHandle = do
          bIn <- newInBox impl
          bOut <- newOutBox bIn
          return (bOut, conc (go bIn nMessagesToHandle []))
          where
            go _bIn 0 _myBooks = pure ()
            go !inBox !workLeft !myBooks =
              let handler =
                    handleMessage inBox $
                      \case
                        NonBlocking (Donate !b) ->
                          pure (workLeft - 1, b : myBooks)
                        Blocking GetBooks replyBox -> do
                          replyTo replyBox myBooks
                          pure (workLeft - 1, myBooks)
               in handler
                    >>= maybe
                      (error "HandleMessage failed!")
                      (uncurry (go inBox))
    let nMessagesPerStore =
          nDonationsPerStore * nDonors
           + nRequestsPerStore * nCustomers
    (bookStoresOutBoxes, bookStoresConc) <-
      unzip <$> replicateM nStores (bookStore nMessagesPerStore)
    let customers = stimes nCustomers (customer bookStoresOutBoxes)
    let donors = mconcat (donor bookStoresOutBoxes <$> [0 .. nDonors - 1])
    runConc (donors <> customers <> mconcat bookStoresConc)

benchmark =
  bgroup
    "BookStore"
    [ bgroup
        "cast"
        [ bench
            ( mboxImplTitle <> " "
                <> show noMessages
                <> " "
                <> show senderNo
                <> " >>= "
                <> show receiverNo
            )
            ( nfAppIO
                impl
                (senderNo, noMessages, receiverNo)
            )
          | noMessages <- [100_000],
            (mboxImplTitle, impl) <-
              [ let x = BoundedMessageBox 16 in (show x, onlyCasts mkExampleBook x),
                let x = UnboundedMessageBox in (show x, onlyCasts mkExampleBook x),
                let x = BoundedMessageBox 4096 in (show x, onlyCasts mkExampleBook x)
              ],
            (senderNo, receiverNo) <-
              [ (1, 1000),
                (10, 100),
                (1, 1),
                (1000, 1)
              ]
        ],
      bgroup
        "call"
        [ bench
            (   " donors: "
                <> show nDonors
                <> " stores: "
                <> show nStores
                <> " customers: "
                <> show nCustomers
                <> " total donations: "
                <> show (nDonors * nDonationsPerStore * nStores )
                <> " total GetBooks: "
                <> show (nCustomers * nGetBooksPerStore * nStores )
            )
            ( nfAppIO
                (castsAndCalls mkExampleBook UnboundedMessageBox)
                ((nDonors, nDonationsPerStore), nStores, (nCustomers, nGetBooksPerStore))
            )
          | ((nDonors, nDonationsPerStore), nStores, (nCustomers, nGetBooksPerStore)) <-
              [ ((1, 1), 1, (1, 1)),
                ((500, 10), 10, (500, 10))
              ]            
        ]
    ]
