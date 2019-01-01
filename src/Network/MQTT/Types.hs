{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Network.MQTT.Types where

import           Control.Applicative             (liftA2, (<|>))
import           Control.Monad                   (replicateM)
import qualified Data.Attoparsec.ByteString.Lazy as A
import           Data.Bits                       (Bits (..), shiftL, testBit,
                                                  (.&.), (.|.))
import qualified Data.ByteString.Lazy            as BL
import           Data.Maybe                      (isJust)
import           Data.Word                       (Word16, Word8)

(≫) :: Bits a => a -> Int -> a
(≫) = shiftR

(≪) :: Bits a => a -> Int -> a
(≪) = shiftL

class ByteMe a where
  toBytes :: a -> [Word8]
  toBytes = BL.unpack . toByteString
  toByteString :: a -> BL.ByteString
  toByteString = BL.pack . toBytes

data ControlPktType = Connect
                    | ConnACK
                    | Publish Bool Word8 Bool -- Dup, QoS, Retain
                    | PubACK -- TODO - for QoS 1
                    | PubRec -- TODO - for QoS 2
                    | PubRel -- TODO - for QoS 2
                    | PubComp -- TODO - for QoS 2
                    | Subscribe
                    | SubACK
                    | Unsubscribe
                    | UnsubACK
                    | PingReq
                    | PingRes
                    | Disconnect deriving(Show, Eq)

boolBit :: Bool -> Word8
boolBit False = 0
boolBit True  = 1

instance ByteMe ControlPktType where
  toByteString = BL.singleton . b

    where
      b Connect = 0x10
      b ConnACK = 0x20
      b (Publish d q r) = 0x30 .|. f
        where f = (db ≪ 3) .|. (qb ≪ 1) .|. rb
              db = boolBit d
              qb = q .&. 0x3
              rb = boolBit r
      b PubACK = 0x40
      b PubRec = 0x50
      b PubRel = 0x62
      b PubComp = 0x70
      b Subscribe = 0x82
      b SubACK = 0x90
      b Unsubscribe = 0xa2
      b UnsubACK = 0xb0
      b PingReq = 0xc0
      b PingRes = 0xd0
      b Disconnect = 0xe0

parseControlPktType :: A.Parser ControlPktType
parseControlPktType = Connect <$ A.word8 0x10
                      <|> ConnACK <$ A.word8 0x20
                      <|> parsePublish
                      <|> PubACK <$ A.word8 0x40
                      <|> PubRec <$ A.word8 0x50
                      <|> PubRel <$ A.word8 0x62
                      <|> PubComp <$ A.word8 0x70
                      <|> Subscribe <$ A.word8 0x82
                      <|> SubACK <$ A.word8 0x90
                      <|> Unsubscribe <$ A.word8 0xa2
                      <|> UnsubACK <$ A.word8 0xb0
                      <|> PingReq <$ A.word8 0xc0
                      <|> PingRes <$ A.word8 0xd0
                      <|> Disconnect <$ A.word8 0xe0
  where
    parsePublish = do
      w <- A.satisfy (\x -> x .&. 0xf0 == 0x30)
      let d = w .&. 0x8 == 0x8
          q = (w ≫ 1) .&. 3
          r = w .&. 1 == 1
      pure $ Publish d q r

parseHdrLen :: A.Parser Int
parseHdrLen = go 0 1
  where
    go :: Int -> Int -> A.Parser Int
    go v m = do
      x <- A.anyWord8
      let a = fromEnum (x .&. 127) * m + v
      if x .&. 128 /= 0
        then go a (m*128)
        else pure a

encodeLength :: Int -> [Word8]
encodeLength n = go (n `quotRem` 128)
  where
    go (x,e)
      | x > 0 = en (e .|. 128) : go (x `quotRem` 128)
      | otherwise = [en e]

    en :: Int -> Word8
    en = toEnum

decodeLength :: [Word8] -> Int
decodeLength = go 0 1
  where
    go v _ [] = v
    go v m (x:xs)
      | x .&. 128 /= 0 = go a (m*128) xs
      | otherwise = a

      where a = d (x .&. 127) * m + v

    d :: Word8 -> Int
    d = fromEnum

encodeWord16 :: Word16 -> BL.ByteString
encodeWord16 a = let (h,l) = a `quotRem` 256 in BL.pack [w h, w l]
    where w = toEnum.fromEnum


blLength :: BL.ByteString -> BL.ByteString
blLength = BL.pack . encodeLength . fromEnum . BL.length

withLength :: BL.ByteString -> BL.ByteString
withLength a = blLength a <> a

instance ByteMe BL.ByteString where
  toByteString a = (encodeWord16 . toEnum . fromEnum . BL.length) a <> a

data ProtocolLevel = Protocol311 deriving(Eq, Show)

instance ByteMe ProtocolLevel where toByteString _ = BL.singleton 4

data LastWill = LastWill {
  _willRetain  :: Bool
  , _willQoS   :: Word8
  , _willTopic :: BL.ByteString
  , _willMsg   :: BL.ByteString
  } deriving(Eq, Show)

data ConnectRequest = ConnectRequest {
  _username       :: Maybe BL.ByteString
  , _password     :: Maybe BL.ByteString
  , _lastWill     :: Maybe LastWill
  , _cleanSession :: Bool
  , _keepAlive    :: Word16
  , _connID       :: BL.ByteString
  } deriving (Eq, Show)

instance ByteMe ConnectRequest where
  toByteString ConnectRequest{..} = toByteString Connect
                                    <> withLength val
    where
      val :: BL.ByteString
      val =  "\NUL\EOTMQTT\EOT" -- MQTT + Protocol311
             <> BL.singleton connBits
             <> encodeWord16 _keepAlive
             <> toByteString _connID
             <> lwt _lastWill
             <> perhaps _username
             <> perhaps _password
      connBits = hasu .|. hasp .|. willBits .|. clean
        where
          hasu = (boolBit $ isJust _username) ≪ 7
          hasp = (boolBit $ isJust _password) ≪ 6
          clean = boolBit _cleanSession ≪ 1
          willBits = case _lastWill of
                       Nothing -> 0
                       Just LastWill{..} -> 4 .|. ((_willQoS .&. 0x3) ≪ 4) .|. (boolBit _willRetain ≪ 5)

      lwt :: Maybe LastWill -> BL.ByteString
      lwt Nothing = mempty
      lwt (Just LastWill{..}) = toByteString _willTopic <> toByteString _willMsg

      perhaps :: Maybe BL.ByteString -> BL.ByteString
      perhaps Nothing  = ""
      perhaps (Just s) = toByteString s

data MQTTPkt = ConnPkt ConnectRequest
             | ConnACKPkt ConnACKFlags
             | PublishPkt PublishRequest
             | SubscribePkt SubscribeRequest
             | SubACKPkt SubscribeResponse
             | UnsubscribePkt UnsubscribeRequest
             | UnsubACKPkt UnsubscribeResponse
             | PingPkt
             | PongPkt
  deriving (Eq, Show)

instance ByteMe MQTTPkt where
  toByteString (ConnPkt x)        = toByteString x
  toByteString (ConnACKPkt x)     = toByteString x
  toByteString (PublishPkt x)     = toByteString x
  toByteString (SubscribePkt x)   = toByteString x
  toByteString (SubACKPkt x)      = toByteString x
  toByteString (UnsubscribePkt x) = toByteString x
  toByteString (UnsubACKPkt x)    = toByteString x
  toByteString PingPkt            = "\192\NUL"
  toByteString PongPkt            = "\208\NUL"

parsePacket :: A.Parser MQTTPkt
parsePacket = parseConnect <|> parseConnectACK
              <|> parsePublish
              <|> parseSubscribe <|> parseSubACK
              <|> parseUnsubscribe <|> parseUnsubACK
              <|> PingPkt <$ A.string "\192\NUL" <|> PongPkt <$ A.string "\208\NUL"

aWord16 :: A.Parser Word16
aWord16 = A.anyWord8 >>= \h -> A.anyWord8 >>= \l -> pure $ (c h ≪ 8) .|. c l
  where c = toEnum . fromEnum

aString :: A.Parser BL.ByteString
aString = do
  n <- aWord16
  s <- A.take (fromEnum n)
  pure $ BL.fromStrict s

parseConnect :: A.Parser MQTTPkt
parseConnect = do
  _ <- A.word8 0x10
  _ <- parseHdrLen
  _ <- A.string "\NUL\EOTMQTT\EOT" -- "MQTT" Protocol level = 4
  connFlagBits <- A.anyWord8
  keepAlive <- aWord16
  cid <- aString
  lwt <- parseLwt connFlagBits
  u <- mstr (testBit connFlagBits 7)
  p <- mstr (testBit connFlagBits 6)
  pure $ ConnPkt ConnectRequest{_connID=cid, _username=u, _password=p,
                                _lastWill=lwt, _keepAlive=keepAlive,
                                _cleanSession=testBit connFlagBits 1}

  where
    mstr :: Bool -> A.Parser (Maybe BL.ByteString)
    mstr False = pure Nothing
    mstr True  = Just <$> aString

    parseLwt bits
      | testBit bits 2 = do
          top <- aString
          msg <- aString
          pure $ Just LastWill{_willTopic=top, _willMsg=msg,
                               _willRetain=testBit bits 5,
                               _willQoS=(bits ≫ 3) .&. 0x3}
      | otherwise = pure Nothing

data ConnACKFlags = ConnACKFlags Bool Word8 deriving (Eq, Show)

instance ByteMe ConnACKFlags where
  toBytes (ConnACKFlags sp rc) = [0x20, 2, boolBit sp, rc]

parseConnectACK :: A.Parser MQTTPkt
parseConnectACK = do
  _ <- A.word8 0x20
  _ <- A.word8 2 -- two bytes left
  ackFlags <- A.anyWord8
  rc <- A.anyWord8
  pure $ ConnACKPkt $ ConnACKFlags (testBit ackFlags 0) rc

data PublishRequest = PublishRequest{
  _pubDup      :: Bool
  , _pubQoS    :: Word8
  , _pubRetain :: Bool
  , _pubTopic  :: BL.ByteString
  , _pubPktID  :: Word8
  , _pubBody   :: BL.ByteString
  } deriving(Eq, Show)

instance ByteMe PublishRequest where
  toByteString PublishRequest{..} = BL.singleton (0x30 .|. f)
                                    <> withLength val
    where f = (db ≪ 3) .|. (qb ≪ 1) .|. rb
          db = boolBit _pubDup
          qb = _pubQoS .&. 0x3
          rb = boolBit _pubRetain
          pktid
            | _pubQoS == 0 = mempty
            | otherwise = BL.singleton _pubPktID
          val = toByteString _pubTopic <> pktid <> toByteString _pubBody

parsePublish :: A.Parser MQTTPkt
parsePublish = do
  w <- A.satisfy (\x -> x .&. 0xf0 == 0x30)
  _ <- parseHdrLen
  let _pubDup = w .&. 0x8 == 0x8
      _pubQoS = (w ≫ 1) .&. 3
      _pubRetain = w .&. 1 == 1
  _pubTopic <- aString
  _pubPktID <- if _pubQoS == 0 then pure 0 else A.anyWord8
  _pubBody <- aString
  pure $ PublishPkt PublishRequest{..}

data SubscribeRequest = SubscribeRequest Word16 [(BL.ByteString, Word8)]
                      deriving(Eq, Show)

instance ByteMe SubscribeRequest where
  toByteString (SubscribeRequest pid sreq) =
    BL.singleton 0x82
    <> withLength (encodeWord16 pid <> reqs)
    where reqs = (BL.concat . map (\(bs,q) -> toByteString bs <> BL.singleton q)) sreq

parseSubscribe :: A.Parser MQTTPkt
parseSubscribe = do
  _ <- A.word8 0x82
  hl <- parseHdrLen
  pid <- aWord16
  content <- A.take (fromEnum hl - 2)
  SubscribePkt . SubscribeRequest pid <$> parseSubs content
    where
      parseSubs l = case A.parseOnly (A.many1 parseSub) l of
                      Left x  -> fail x
                      Right x -> pure x
      parseSub = liftA2 (,) aString A.anyWord8

data SubscribeResponse = SubscribeResponse Word16 [Word8] deriving (Eq, Show)

instance ByteMe SubscribeResponse where
  toByteString (SubscribeResponse pid sres) =
    BL.singleton 0x90 <> withLength (encodeWord16 pid <> BL.pack sres)

parseSubACK :: A.Parser MQTTPkt
parseSubACK = do
  _ <- A.word8 0x90
  hl <- parseHdrLen
  pid <- aWord16
  SubACKPkt . SubscribeResponse pid <$> replicateM (hl-2) A.anyWord8

data UnsubscribeRequest = UnsubscribeRequest Word16 [BL.ByteString]
                        deriving(Eq, Show)

instance ByteMe UnsubscribeRequest where
  toByteString (UnsubscribeRequest pid sreq) =
    BL.singleton 0xa2
    <> withLength (encodeWord16 pid <> mconcat (toByteString <$> sreq))

parseUnsubscribe :: A.Parser MQTTPkt
parseUnsubscribe = do
  _ <- A.word8 0xa2
  hl <- parseHdrLen
  pid <- aWord16
  content <- A.take (fromEnum hl - 2)
  UnsubscribePkt . UnsubscribeRequest pid <$> parseSubs content
    where
      parseSubs l = case A.parseOnly (A.many1 aString) l of
                      Left x  -> fail x
                      Right x -> pure x

newtype UnsubscribeResponse = UnsubscribeResponse Word16 deriving(Eq, Show)

instance ByteMe UnsubscribeResponse where
  toByteString (UnsubscribeResponse pid) = BL.singleton 0xb0 <> withLength (encodeWord16 pid)

parseUnsubACK :: A.Parser MQTTPkt
parseUnsubACK = do
  _ <- A.word8 0xb0
  _ <- parseHdrLen
  UnsubACKPkt . UnsubscribeResponse <$> aWord16
