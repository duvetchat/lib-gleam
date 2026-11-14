import gleam/erlang/process.{type Subject}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/time/duration.{type Duration}
import libduvet/gateway/feed.{type Feed, type FeedMessage, FeedClosed, Payload}
import libduvet/gateway/manager
import libduvet/gateway/voice_states.{type VoiceStates}
import libduvet/model/envelope
import libduvet/model/event

/// Voice and call signalling over the gateway: the typed messages a client
/// sends to be in a space's voice room or a conversation's call, and to
/// negotiate its peer connection with the gateway.
pub opaque type WebRTCController {
  WebRTCController(
    manager: manager.GatewayManager,
    subject: Subject(Message),
    updates: Feed,
    states: VoiceStates,
  )
}

type Message {
  Dispose(reply: Subject(Nil))
}

pub fn start(manager: manager.GatewayManager) -> WebRTCController {
  let states = voice_states.start()
  let updates = feed.start()
  let ready = process.new_subject()
  let manager_feed = manager.feed(manager)
  let _ =
    process.spawn(fn() {
      let listener = feed.subscribe(manager_feed)
      let subject = process.new_subject()
      process.send(ready, subject)
      loop(states, updates, listener, subject)
    })
  WebRTCController(
    manager: manager,
    subject: process.receive_forever(ready),
    updates: updates,
    states: states,
  )
}

fn loop(
  states: VoiceStates,
  updates: Feed,
  listener: Subject(FeedMessage),
  subject: Subject(Message),
) -> Nil {
  let selector =
    process.new_selector()
    |> process.select_map(listener, FromFeed)
    |> process.select_map(subject, FromCaller)
  case process.selector_receive_forever(selector) {
    FromFeed(Payload(payload)) -> {
      handle(states, updates, payload)
      loop(states, updates, listener, subject)
    }
    FromFeed(_) -> loop(states, updates, listener, subject)
    FromCaller(Dispose(reply)) -> {
      process.send(reply, Nil)
      feed.publish(updates, FeedClosed)
    }
    FromCaller(_) -> loop(states, updates, listener, subject)
  }
}

type Received {
  FromFeed(message: FeedMessage)
  FromCaller(message: Message)
}

fn handle(
  states: VoiceStates,
  updates: Feed,
  payload: envelope.GatewayEventPayload,
) {
  case payload {
    envelope.ReadyEvent(data) -> {
      let calls = case data.active_calls {
        Some(calls) -> calls
        None -> []
      }
      voice_states.reset(states, calls)
    }
    envelope.SpaceCreateEvent(data) -> voice_states.space(states, data)
    envelope.VoiceStateUpdatedEvent(data) ->
      case voice_states.apply(states, data) {
        True -> feed.publish(updates, Payload(payload))
        False -> Nil
      }
    envelope.CallOngoingPayloadEvent(data) -> voice_states.ongoing(states, data)
    envelope.CallEndedPayloadEvent(data) ->
      voice_states.forget(states, data.conversation_id)
    envelope.RoomDeletedEvent(data) -> voice_states.forget(states, data.id)
    _ -> Nil
  }
}

/// The VOICE_STATE_UPDATEs that changed [voice_states], which is up to date
/// when they arrive; late ones are left out.
pub fn updates(controller: WebRTCController) -> Feed {
  controller.updates
}

/// Who's in voice where, as the gateway reports it.
pub fn voice_states(controller: WebRTCController) -> VoiceStates {
  controller.states
}

/// Every event the manager's shards send, for the gateway's answers (voice
/// joined, ICE candidates, offers, calls).
pub fn events(controller: WebRTCController) -> Feed {
  manager.feed(controller.manager)
}

pub fn connection(controller: WebRTCController) -> Option(Int) {
  manager.connection(controller.manager)
}

pub fn silence_before_ready(controller: WebRTCController) -> Duration {
  manager.silence_before_ready(controller.manager)
}

/// Cancels the gateway subscription and closes the updates feed.
pub fn dispose(controller: WebRTCController) -> Nil {
  let reply = process.new_subject()
  process.send(controller.subject, Dispose(reply))
  process.receive_forever(reply)
  feed.close(controller.updates)
}

// ---------------------------------------------------------------------------
// Voice
// ---------------------------------------------------------------------------

/// VOICE_JOIN: joins [room_id] (a voice room, or a call's conversation) with
/// the peer connection's [offer]. [tracks] tags the transceivers that send a
/// camera, by mid.
pub fn join_voice(
  controller: WebRTCController,
  room_id: String,
  offer: event.SessionDescription,
  tracks: List(#(String, String)),
  video_off: Bool,
) -> Bool {
  send(
    controller,
    "VOICE_JOIN",
    list.flatten([
      [
        #("room_id", json.string(room_id)),
        #("offer", event.session_description_to_json(offer)),
      ],
      case tracks {
        [] -> []
        tracks -> [
          #(
            "tracks",
            json.object(
              list.map(tracks, fn(pair) { #(pair.0, json.string(pair.1)) }),
            ),
          ),
        ]
      },
      [#("video_off", json.bool(video_off))],
    ]),
  )
}

/// VOICE_LEAVE: leaves [room_id]'s voice.
pub fn leave_voice(controller: WebRTCController, room_id: String) -> Bool {
  send(controller, "VOICE_LEAVE", [#("room_id", json.string(room_id))])
}

/// VOICE_SYNC: the client's whole voice state in [room_id]. Every field is
/// required: one left out would turn that off. [watching] is whose screen
/// share the user watches there, by user ID, in the order they opened them:
/// the gateway keeps 25 at most, without repeats or the user's own ID.
pub fn sync_voice(
  controller: WebRTCController,
  room_id: String,
  muted: Bool,
  deafened: Bool,
  screen_sharing: Bool,
  camera: Bool,
  video_off: Bool,
  watching: List(String),
) -> Bool {
  send(controller, "VOICE_SYNC", [
    #("room_id", json.string(room_id)),
    #("muted", json.bool(muted)),
    #("deafened", json.bool(deafened)),
    #("screen_sharing", json.bool(screen_sharing)),
    #("camera", json.bool(camera)),
    #("video_off", json.bool(video_off)),
    #("watching", json.array(watching, json.string)),
  ])
}

/// WEBRTC_ICE_CANDIDATE: one of the peer connection's ICE candidates.
pub fn send_ice_candidate(
  controller: WebRTCController,
  room_id: String,
  candidate: event.IceCandidateInit,
) -> Bool {
  send(controller, "WEBRTC_ICE_CANDIDATE", [
    #("room_id", json.string(room_id)),
    #("candidate", event.ice_candidate_init_to_json(candidate)),
  ])
}

/// WEBRTC_ANSWER: the answer to the gateway's offer.
pub fn send_answer(
  controller: WebRTCController,
  room_id: String,
  answer: event.SessionDescription,
) -> Bool {
  send(controller, "WEBRTC_ANSWER", [
    #("room_id", json.string(room_id)),
    #("answer", event.session_description_to_json(answer)),
  ])
}

/// WEBRTC_RENEGOTIATE_OFFER: the client's own renegotiation; the gateway
/// answers with WEBRTC_RENEGOTIATE_ANSWER.
pub fn send_renegotiate_offer(
  controller: WebRTCController,
  room_id: String,
  offer: event.SessionDescription,
  tracks: List(#(String, String)),
) -> Bool {
  send(
    controller,
    "WEBRTC_RENEGOTIATE_OFFER",
    list.flatten([
      [
        #("room_id", json.string(room_id)),
        #("offer", event.session_description_to_json(offer)),
      ],
      case tracks {
        [] -> []
        tracks -> [
          #(
            "tracks",
            json.object(
              list.map(tracks, fn(pair) { #(pair.0, json.string(pair.1)) }),
            ),
          ),
        ]
      },
    ]),
  )
}

// ---------------------------------------------------------------------------
// Calls
// ---------------------------------------------------------------------------

/// CALL_INITIATE: rings [member_ids] with CALL_INCOMING.
pub fn initiate_call(
  controller: WebRTCController,
  conversation_id: String,
  member_ids: List(String),
) -> Bool {
  send(controller, "CALL_INITIATE", [
    #("conversation_id", json.string(conversation_id)),
    #("member_ids", json.array(member_ids, json.string)),
  ])
}

/// CALL_ACCEPT: answers a call.
pub fn accept_call(
  controller: WebRTCController,
  conversation_id: String,
) -> Bool {
  send(controller, "CALL_ACCEPT", [
    #("conversation_id", json.string(conversation_id)),
  ])
}

/// CALL_DECLINE: turns a call down on all of the user's devices.
pub fn decline_call(
  controller: WebRTCController,
  conversation_id: String,
) -> Bool {
  send(controller, "CALL_DECLINE", [
    #("conversation_id", json.string(conversation_id)),
  ])
}

/// CALL_CANCEL: ends the call for everyone.
pub fn cancel_call(
  controller: WebRTCController,
  conversation_id: String,
) -> Bool {
  send(controller, "CALL_CANCEL", [
    #("conversation_id", json.string(conversation_id)),
  ])
}

/// CALL_LEAVE: leaves a call's voice; the call ends when nobody's left.
pub fn leave_call(
  controller: WebRTCController,
  conversation_id: String,
) -> Bool {
  send(controller, "CALL_LEAVE", [
    #("conversation_id", json.string(conversation_id)),
  ])
}

fn send(
  controller: WebRTCController,
  type_: String,
  data: List(#(String, json.Json)),
) -> Bool {
  case manager.send_message(controller.manager, type_, json.object(data)) {
    Ok(sent) -> sent
    Error(Nil) -> False
  }
}
