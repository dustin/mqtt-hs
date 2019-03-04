# Changelog for net-mqtt

## 0.2.4.1

Link QoS2 completion thread on subscriber.

An exception from a subscriber callback could be silently dropped
without completing the handshake which would then cause the MQTT
broker to just stop sending messages to the subscriber.
Unfortunately, the broker (at least mosquitto) still responds to pings
and doesn't give any useful notification that it's no longer sending
messages.

## 0.2.4.0

Introduced `Filter` type alias to distinguish from `Topic`.

Reintroduced timeout management at the protocol layer, dropping a
connection when a pong response hasn't come in in a while (~3x longer
than the current 30s ping rate).  This was mostly after noticing
mosquitto do really weird things where it seemed to just forget about
all my active connections (other clients figured that out and dropped
and reconnected).

## 0.2.3.1

Fixed up github links.

## 0.2.3.0

Added Network.MQTT.Topic with `match` to test `Topic`s against wildcards.

## 0.2.2.0

Added connectURI to make it easier to connect to mqtt or mqtts via
URI.

## 0.2.1.0

No externally visible changes, but a few bug fixes I found when
writing an application that published in QoS < 2.  QoS 0 would likely
not transmit (which is probably fine according to the spec, but not
very desirable) and QoS1 didn't check its ACKs, so it would continue
to retry after the server ACKd the message.

## 0.2.0.0

### API Change

Subscriber callbacks now include the MQTT client as the first
argument.  This breaks a circular dependency that prevented callbacks
from being able to publish messages easily.

### Other

Updated to stackage LTS 13.2

