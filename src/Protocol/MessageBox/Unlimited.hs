-- | Thread safe queues for message passing
-- between many concurrent processes.
--
-- This message box is __UNLIMITED__.
--
-- Good single producer/single consumer performance
--
-- If you are sure that the producer(s) send messages
-- at a lower rate than the rate at which the consumer
-- consumes messages, use this module.
--
-- Otherwise use the more conservative
-- "Protocol.MessageBox.Limited" module.
module Protocol.MessageBox.Unlimited
  ( create,
    receive,
    tryReceive,
    newInput,
    deliver,
    MessageBox (),
    Input (),
    UnlimitedMessageBox(..),
  )
where

import qualified Control.Concurrent as IO
import qualified Control.Concurrent.Chan.Unagi.NoBlocking as Unagi
import Data.Functor ( ($>) )
import qualified Protocol.MessageBox.Class as Class
import UnliftIO
  ( MonadIO (liftIO),
    MonadUnliftIO,
  )
import Protocol.Future ( Future(..) )

-- | Create a 'MessageBox'.
--
-- From a 'MessageBox' a corresponding 'Input' can
-- be made, that can be passed to some potential
-- communication partners.
{-# INLINE create #-}
create :: MonadUnliftIO m => m (MessageBox a)
create = do
  (!inChan, !outChan) <- liftIO Unagi.newChan
  return $! MkOutput inChan outChan

-- | Wait for and receive a message from a 'MessageBox'.
{-# INLINE receive #-}
receive :: MonadUnliftIO m => MessageBox a -> m a
receive (MkOutput _ !s) =
  liftIO (Unagi.readChan IO.yield s)

-- | Try to receive a message from a 'MessageBox',
-- return @Nothing@ if the queue is empty.
{-# INLINE tryReceive #-}
tryReceive :: MonadUnliftIO m => MessageBox a -> m (Future a)
tryReceive (MkOutput _ !s) = liftIO $ do
  !promise <- Unagi.tryReadChan s
  return (Future (Unagi.tryRead promise))

-- | Create an 'Input' to write the items
-- that the given 'MessageBox' receives.
{-# INLINE newInput #-}
newInput :: MonadUnliftIO m => MessageBox a -> m (Input a)
newInput (MkOutput !s _) = return $! MkInput s

-- | Put a message into the 'Input'
-- of a 'MessageBox', such that the process
-- reading the 'MessageBox' receives the message.
{-# INLINE deliver #-}
deliver :: MonadUnliftIO m => Input a -> a -> m ()
deliver (MkInput !s) !a =
  liftIO $ Unagi.writeChan s a

-- | A message queue out of which messages can
--   by 'receive'd.
--
-- This is the counter part of 'Input'. Can be
-- used for reading messages.
--
-- Messages can be received by 'receive' or 'tryReceive'.
data MessageBox a
  = MkOutput
      !(Unagi.InChan a)
      !(Unagi.OutChan a)

-- | A message queue into which messages can be enqued by,
--   e.g. 'deliver'.
--   Messages can be received from an 'MessageBox`.
--
--   The 'Input' is the counter part of a 'MessageBox'.
newtype Input a = MkInput (Unagi.InChan a)

-- | The (empty) configuration for creating 
-- 'MessageBox'es using the 'Class.IsMessageBoxFactory' methods.
data UnlimitedMessageBox = UnlimitedMessageBox
  deriving stock Show

instance Class.IsMessageBoxFactory UnlimitedMessageBox where
  type MessageBox UnlimitedMessageBox = MessageBox
  {-# INLINE newMessageBox #-}
  newMessageBox UnlimitedMessageBox = create

-- | A blocking instance that invokes 'receive'.
instance Class.IsMessageBox MessageBox where
  type Input MessageBox = Input
  {-# INLINE receive #-}
  receive !i = Just <$> receive i
  {-# INLINE tryReceive #-}
  tryReceive !i = tryReceive i
  {-# INLINE newInput #-}
  newInput !i = newInput i

-- | A blocking instance that invokes 'deliver'.
instance Class.IsInput Input where
  {-# INLINE deliver #-}
  deliver !o !m = deliver o m $> True
