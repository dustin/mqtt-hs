# mqtt

An [MQTT][mqtt] client for Haskell.

## Example

### Publish

```haskell
main :: IO
main = do
  mc <- runClient mqttConfig{}
  publish mc "tmp/topic" "hello!" False
```

### Subscribe

```haskell
main :: IO
main = do
  mc <- runClient mqttConfig{_msgCB=Just msgReceived}
  print =<< subscribe mc [("tmp/topic1", QoS0), ("tmp/topic2", QoS0)]
  print =<< waitForClient mc   -- wait for the the client to disconnect

  where
    msgReceived t m = print (t,m)
```

[mqtt]: http://mqtt.org/
