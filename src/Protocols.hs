{-# LANGUAGE StrictData #-}
-- | Define, handle and compose messages belonging to a /protocol/.
-- 
-- This module helps to build a safe, performant and convenient
-- programs using concurrent processes, exchanging messages with
-- each other.
--
-- It provides some GADT based type level support for preventing 
-- simple bugs possible in programs incorporating synchronous and 
-- asynchronous message passing, by making it a compile error
-- to wait for a reply to a 'Call' 'Message' or to reply a wrong
-- answer to a 'Cast' 'Message'.
--
-- It is a thin layer on STM und unliftio. 
--
-- This is not a module to aid serialization of binary packets.
module Protocols (
    Message (),
    Pdu,
    ResponseKind(..),
    CallId(..),
    ReplyBox(),    
    CallFailure(..)
    ) where


import Data.Kind
import Data.Text (Text)
import Data.Word
import Numeric.Natural (Natural)
import System.Mem.Weak (Weak)
import UnliftIO
import UnliftIO.STM
import qualified Protocols.MessageBox as MessageBox
import Protocols.UniqueCallIds 

-- | This family allows declaration of valid 
-- messages of a protocol defined by a user provided tag-type, 
-- paired with a 'ResponseKind' that declares if and what 
-- response is valid for a message.
--
-- _PDU_ is the abbreviation of _P_rotocol _D_ata _U_nit,
-- but could have been called @Method apiTag@ or @Command apiTag@
-- was well.
--
-- The first type parameter is a phantom type - probably uninhabited -
-- indicating a set of messages commonly describing an API, or
-- protocol.
--
-- The second type parameter indicates if a message requires the
-- receiver to send a reply back to the blocked and waiting 
-- sender, or if no reply is necessary.
--
-- Since 'Pdu' instances can be generalised algebraic data types
-- the specific 'ResponseKind'
--
-- Example:
--
-- > 
-- > data LightControl
-- > 
-- > type LampId = Int
-- >
-- > data instance Pdu LightControl r where
-- >   GetLamps :: Pdu LigthControl (Responding [LampId])
-- >   SwitchOn :: LampId -> Pdu LigthControl NoResponse
-- > 
data family Pdu protocolTag :: ResponseKind -> Type

-- | Indicates if a 'Pdu' requires the
-- receiver to send a reply or not.
data ResponseKind where
  -- | Indicates that a 'Pdu' value is sent _one-way_.
  --
  -- Values of a 'Pdu' instance with 'NoResponse' as second parameter 
  -- are received wrapped into a 'Message'.
  NoResponse :: ResponseKind
  -- | Indicates that a 'Pdu' value requires the receiver
  -- to send a reply of the given type.
  --
  -- Values of a 'Pdu' instance with 'Responding' as second parameter 
  -- are received wrapped into a 'Call'.
  Responding :: Type -> ResponseKind

-- | A message valid for some user defined @protocol@.
--
-- The @protocol@ tag (phantom-) type defines the 
-- messages allowed here, declared by the instance of 
-- 'Pdu' for 'protocol'.
data Message protocol where
  -- | Wraps a 'Pdu' with a 'ResponseKind' of 'Responding' @result@.
  --
  -- Such a message can formed by using 'call'.
  --
  -- A 'Call' contains a 'ReplyBox' that can be
  -- used to send the reply to the other process 
  -- blocking on 'call'
  --
  Call ::
    Pdu protocol (Responding result) ->
    ReplyBox result ->
    Message protocol
  -- | If the 'Pdu' has a 'ResponseKind' of 'NoResponse' 
  -- it has fire-and-forget semantics.
  --
  -- The smart constructor 'cast' can be used to
  -- this message.
  Cast ::
    Pdu protocol NoResponse ->
    Message protocol

-- | This is like 'OutBox', it can be used
-- by the receiver of a 'Call'
-- to either send a reply using 'reply'
-- or to fail/abort the request using 'sendRequestError'
data ReplyBox a = MkReplyBox
  { _replyBoxCallId :: CallId,
    _replyBoxOutBox :: MessageBox.OutBox (CallId, Either CallFailure a)
  }

-- | The failures that the receiver of a 'Responding' 'Pdu', i.e. a 'Call',
-- can communicate to the /caller/, in order to indicate that
-- processing a request did not or will not lead to the result the 
-- caller is blocked waiting for.
data CallFailure where
  -- | Failed to send the call to the corresponding 'MessageBox.OutBox'
  CouldNotDeliverCallMessage :: MessageBox.OutBoxFailure -> CallFailure
  -- | The request has failed /for reasons/.
  CallFailed :: CallFailure


-- | Enqueue a 'Cast' 'Message' into an 'OutBox'.
-- This is just for symetry to 'call', this is 
-- equivalent to: @\obox -> MessageBox.trySend obox . Cast@
cast ::  
  MessageBox.OutBox (Message protocol) ->
  Pdu protocol NoResponse ->
  m (Maybe MessageBox.OutBoxFailure)
cast obox !msg = MessageBox.trySend obox (Cast msg)


-- | Enqueue a 'Call' 'Message' into an 'OutBox'.
call ::
  MessageBox.OutBox (Message protocol) ->
  Pdu protocol (Responding result) ->
  m (Either CallFailure result)
call obox !pdu = do 
    let !msg = Call pdu replybox