# Changelog for net-mqtt

## 0.6.1.1

Add connection checks to publish phases.

Having a broker/connection die in the middle of a publish in QoS > 0
could result in a thread waiting indefinitely for the response that
would not ever arrive.

## 0.6.1.0

Users can now specify TLSSettings for mqtts:// and wss:// connections.

Small bit of refactoring of main threads used by the client.  It's a
bit easier to reason about their lifecycle now.

All (at least most) of the threads in use by the client are named so
when you're looking at an eventlog, you can see what's coming and
going.

## 0.6.0.2

Export MQTTException (thrown from various internal bits).

Added isConnectedSTM for verifying connection state inside of STM
transactions (e.g., verifying you're connected while also waiting for
a value in a TChan).

Also, mqtt-watch reconnects on error now.

## 0.6.0.1

Relaxed QuickCheck constraint slightly.

Added connection timeout.

## 0.6.0.0

Many changes went into this release.

### New Features

* WebSocket support (ws:// and wss://)
* Added the `mqtt-watch` CLI tool (which I use a lot)
* Lots of work on correctness WRT connection and callback failures.
* Low-Level callbacks (providing all the details of the published
  message)
* Added `runMQTTConduit` to allow running the client over any Conduit
  provider.

### Incompatibilities

As part of adding features and improving correctness, I've made a few
API changes.

* `waitForClient` now throws an exception on failure.  This greatly
  simplified usage and has made a variety of my applications more
  reliable when networks and computers fail.
* Callbacks are now `MessageCallback`.  This primarily allowed me to
  separate `SimpleCallback` (the thing most apps want) and
  `LowLevelCallback` (a thing I needed when building an MQTT bridge).
* Removed `runClient` and `runClientTLS` from the API.  They don't
  provide any value over `connectURI` or `runMQTTConduit`.
* All callbacks are now asynchronous.  Before, QoS2 would be by
  necessity, but a bad callback could cause problems with the
  machinery, so they're all independent now.  This may not be
  noticeable in most applications, but it's something to consider.

## 0.5.1.0

The QuickCheck Arbitrary instances are exported in a module now,
allowing programs to generate useful tests other implementations of
mqtt.  I've been using this package to test a C implementation.

Also, don't allow 3.1.1 to generate a password without a username.
That's kind of a weird limitation in the older protocol I'm not sure
anyone's run into, but the spec says not to encode things on the wire
that way, so it's useful for interop testing.

## 0.5.0.2

With a few attempts to misuse the library, I found some places where
error messages weren't useful enough.  There were still two cases
where failures turned into indefinite STM errors instead of more
informative errors.  1) when the broker declined your connection and
2) when the broker refused your connection.  These are errors at
differnet layers, so were addressed differently, but should be
informative in both cases now.

Unsubscribe was apparently broken in MQTT 5 as well.  I'd never tried
to use it, and just happened to notice it wasn't quite right.

## 0.5.0.1

Now with no known issues.

0.5.0.0 was released without consulting the github issues page.  There
were two open bugs -- one had already been fixed in the development of
0.5, but another was still present.

0.5.0.0 named the default subscription options `defaultSubOptions`,
but that's inconsistent with other defaults, so it was renamed to
`subOptions`.  This is technically an API incompatibility being
introduced and I wouldn't normally do that, but the API's been out for
a few hours, so I'm preeptively asking for forgiveness.

## 0.5.0.0

Major release for MQTT version 5.

The API is mostly the same, but a list of Property values is passed in
and returned from a few different fields.

Subscribe responses are now more detailed in the error case, and also
return a `[Property]`.

Connections default to `Protocol311` (3.1.1), and all behavior should
be backwards compatible in these cases.  i.e., you can write code as
if it were destined for a v5 broker, but properties won't be sent and
responses will be inferred.  If you specify your `_protocol` as
`Protocol50` in your `MQTTConfig`, the new features should all work.

Various bugs were fixed along the path of making v5 compatibility, but
I'm pretty sure there's one left somewhere.

## 0.2.4.2

Don't set a message ID of 0.

This had been working fine for a while, but starting in mosquitto 1.6,
the server would just hang up on a subscribe request with a message ID
of zero.

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

