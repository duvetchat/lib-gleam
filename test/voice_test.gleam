import gleam/dict
import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/order
import gleam/time/duration
import gleam/time/timestamp
import gleeunit
import gleeunit/should
import libduvet/api_router
import libduvet/gateway/events
import libduvet/gateway/feed
import libduvet/gateway/manager
import libduvet/gateway/voice_states
import libduvet/gateway/webrtc
import libduvet/http/client as rest
import libduvet/http/transport
import libduvet/model/decoding
import libduvet/model/event
import libduvet/model/ready
import support/fake_gateway

pub fn main() -> Nil {
  gleeunit.main()
}

const token = "token"

fn router_on(server: fake_gateway.Server) -> api_router.ApiRouter {
  let port = int.to_string(fake_gateway.port(server))
  api_router.ApiRouter(
    api: "127.0.0.1:" <> port,
    ws: "127.0.0.1:" <> port,
    base: "127.0.0.1:" <> port,
    cdn: "none",
    secure: False,
  )
}

fn api_on(server: fake_gateway.Server) -> rest.RestClient {
  rest.new(transport.hackney(5000), router_on(server), token, "", 20_000)
}

fn manager_on(server: fake_gateway.Server) -> manager.GatewayManager {
  manager.config(api_on(server))
  |> manager.with_router(router_on(server))
  |> manager.start
}

fn state(
  room: String,
  user: String,
  version: Int,
  joined: Bool,
  muted: Bool,
) -> event.VoiceStateEvent {
  event.VoiceStateEvent(
    room_id: room,
    user_id: user,
    joined: joined,
    muted: muted,
    deafened: False,
    screen_sharing: False,
    camera: False,
    version: version,
  )
}

fn parsed(text: String) -> decoding.Object {
  case
    json.parse(from: text, using: decode.dict(decode.string, decode.dynamic))
  {
    Ok(object) -> object
    Error(_) -> decoding.empty_object()
  }
}

fn space_payload(
  rooms: List(String),
  states: List(#(String, String, Int)),
) -> event.GatewaySpaceCreatePayload {
  let room_object =
    rooms
    |> list.map(fn(id) {
      #(
        id,
        json.object([
          #("id", json.string(id)),
          #("space_id", json.string("s1")),
          #("name", json.string(id)),
          #("type", json.int(2)),
          #("position", json.int(0)),
          #("created_at", json.string("2026-10-23T09:00:00Z")),
          #("updated_at", json.string("2026-10-23T09:00:00Z")),
        ]),
      )
    })
    |> json.object
  let voice_states =
    states
    |> list.map(fn(entry) {
      let #(room, user, version) = entry
      json.object([
        #("room_id", json.string(room)),
        #("user_id", json.string(user)),
        #("muted", json.bool(False)),
        #("deafened", json.bool(False)),
        #("screen_sharing", json.bool(False)),
        #("camera", json.bool(False)),
        #("version", json.int(version)),
      ])
    })
    |> json.array(fn(value) { value })
  let document =
    json.object([
      #(
        "space",
        json.object([
          #("id", json.string("s1")),
          #("name", json.string("Guild")),
          #("owner_id", json.string("u1")),
          #("created_at", json.string("2026-10-23T09:00:00Z")),
          #("updated_at", json.string("2026-10-23T09:00:00Z")),
        ]),
      ),
      #("rooms", room_object),
      #("roles_permissions", json.object([])),
      #("owner_id", json.string("u1")),
      #("voice_states", voice_states),
    ])
  json.to_string(document) |> parsed |> event.space_create_payload_from_json
}

fn call_state(user: String, version: Int) -> ready.CallVoiceState {
  ready.CallVoiceState(
    user_id: user,
    muted: True,
    deafened: False,
    screen_sharing: False,
    camera: False,
    version: version,
  )
}

fn active_call(user: String, version: Int) -> ready.GatewayReadyActiveCall {
  ready.GatewayReadyActiveCall(
    conversation_id: "c1",
    initiator_id: "leo",
    initiator_name: None,
    initiator_avatar: None,
    voice_states: Some([call_state(user, version)]),
    ringing: None,
    answered: None,
  )
}

// ---------------------------------------------------------------------------
// VoiceStates
// ---------------------------------------------------------------------------

pub fn an_update_older_than_one_applied_is_dropped_test() {
  let states = voice_states.start()
  should.be_true(voice_states.apply(states, state("r1", "maya", 5, True, False)))
  should.be_true(voice_states.apply(states, state("r1", "maya", 7, True, True)))
  // A late one, from before the mute.
  should.be_false(voice_states.apply(
    states,
    state("r1", "maya", 6, True, False),
  ))
  let assert [participant] = voice_states.participants_in(states, "r1")
  should.be_true(participant.muted)
  // The same state again (a call's catch-up when joining it).
  should.be_true(voice_states.apply(states, state("r1", "maya", 7, True, True)))

  should.be_true(voice_states.apply(
    states,
    state("r1", "maya", 9, False, False),
  ))
  should.equal(voice_states.participants_in(states, "r1"), [])
  should.equal(voice_states.rooms(states), dict.new())
  // A "joined" that came after the leave doesn't bring her back.
  should.be_false(voice_states.apply(
    states,
    state("r1", "maya", 8, True, False),
  ))
  should.equal(voice_states.participants_in(states, "r1"), [])
}

pub fn ready_starts_over_with_its_calls_test() {
  let states = voice_states.start()
  let _ = voice_states.apply(states, state("r1", "maya", 9, True, False))
  voice_states.reset(states, [active_call("leo", 3)])
  should.equal(voice_states.participants_in(states, "r1"), [])
  let assert [leo] = voice_states.participants_in(states, "c1")
  should.equal(#(leo.user_id, leo.muted, leo.version), #("leo", True, 3))
  // The new session's versions start from what READY said.
  should.be_true(voice_states.apply(states, state("r1", "maya", 1, True, False)))
  should.be_false(voice_states.apply(states, state("c1", "leo", 2, True, False)))
}

pub fn space_create_replaces_its_rooms_but_not_with_older_states_test() {
  let states = voice_states.start()
  let _ = voice_states.apply(states, state("r1", "gone", 1, True, False))
  let _ = voice_states.apply(states, state("r2", "maya", 20, False, False))
  let _ = voice_states.apply(states, state("other", "leo", 1, True, False))
  voice_states.space(
    states,
    space_payload(["r1", "r2"], [#("r1", "ana", 4), #("r2", "maya", 10)]),
  )
  should.equal(
    list.map(voice_states.participants_in(states, "r1"), fn(p) { p.user_id }),
    ["ana"],
  )
  should.equal(voice_states.participants_in(states, "r2"), [])
  let assert [leo] = voice_states.participants_in(states, "other")
  should.equal(leo.user_id, "leo")
}

pub fn call_ongoing_replaces_its_call_but_not_with_older_states_test() {
  let states = voice_states.start()
  let _ = voice_states.apply(states, state("c1", "gone", 1, True, False))
  let _ = voice_states.apply(states, state("c1", "maya", 20, False, False))
  let _ = voice_states.apply(states, state("other", "leo", 1, True, False))
  voice_states.ongoing(
    states,
    event.CallOngoingEvent(
      conversation_id: "c1",
      initiator_id: "leo",
      voice_states: Some([call_state("ana", 4), call_state("maya", 10)]),
    ),
  )
  should.equal(
    list.map(voice_states.participants_in(states, "c1"), fn(p) { p.user_id }),
    ["ana"],
  )
  let assert [leo] = voice_states.participants_in(states, "other")
  should.equal(leo.user_id, "leo")
  // Nobody in its voice any more.
  voice_states.ongoing(
    states,
    event.CallOngoingEvent(
      conversation_id: "c1",
      initiator_id: "leo",
      voice_states: None,
    ),
  )
  should.equal(voice_states.participants_in(states, "c1"), [])
}

pub fn a_forgotten_room_is_empty_test() {
  let states = voice_states.start()
  let _ = voice_states.apply(states, state("c1", "maya", 1, True, False))
  voice_states.forget(states, "c1")
  should.equal(voice_states.participants_in(states, "c1"), [])
}

// ---------------------------------------------------------------------------
// WebRTCController
// ---------------------------------------------------------------------------

type Harness {
  Harness(
    server: fake_gateway.Server,
    manager: manager.GatewayManager,
    controller: webrtc.WebRTCController,
    listener: events.Listener,
  )
}

fn controlled_gateway() -> Harness {
  let server = fake_gateway.start()
  let mgr = manager_on(server)
  let controller = webrtc.start(mgr)
  let listener = feed.subscribe(manager.feed(mgr))
  Harness(
    server: server,
    manager: mgr,
    controller: controller,
    listener: listener,
  )
}

fn connect(harness: Harness) -> Nil {
  let assert Ok(Nil) = manager.connect_all(harness.manager, 1)
  let assert Ok(_) = events.await_ready(harness.listener, 5000)
  Nil
}

fn await_participants(
  controller: webrtc.WebRTCController,
  room_id: String,
  timeout_ms: Int,
  done: fn(List(voice_states.VoiceParticipant)) -> Bool,
) -> List(voice_states.VoiceParticipant) {
  let deadline =
    timestamp.add(timestamp.system_time(), duration.milliseconds(timeout_ms))
  await_participants_loop(controller, room_id, deadline, done)
}

fn await_participants_loop(
  controller: webrtc.WebRTCController,
  room_id: String,
  deadline: timestamp.Timestamp,
  done: fn(List(voice_states.VoiceParticipant)) -> Bool,
) -> List(voice_states.VoiceParticipant) {
  let participants =
    voice_states.participants_in(webrtc.voice_states(controller), room_id)
  let left = timestamp.difference(timestamp.system_time(), deadline)
  case
    done(participants)
    || duration.compare(left, duration.milliseconds(0)) != order.Gt
  {
    True -> participants
    False -> {
      process.sleep(10)
      await_participants_loop(controller, room_id, deadline, done)
    }
  }
}

fn close(harness: Harness) -> Nil {
  webrtc.dispose(harness.controller)
  manager.destroy(harness.manager)
  fake_gateway.stop(harness.server)
}

fn expected_data(pairs: List(#(String, dynamic.Dynamic))) -> decoding.Object {
  dict.from_list(pairs)
}

pub fn nothing_goes_out_before_a_socket_is_open_test() {
  let harness = controlled_gateway()
  should.equal(webrtc.connection(harness.controller), None)
  should.be_false(webrtc.leave_voice(harness.controller, "r1"))
  should.be_false(webrtc.accept_call(harness.controller, "c1"))
  close(harness)
}

pub fn sends_each_message_as_the_gateway_reads_it_test() {
  let harness = controlled_gateway()
  connect(harness)
  should.equal(webrtc.connection(harness.controller), Some(1))

  let offer = event.SessionDescription(type_: "offer", sdp: "v=0 offer")
  let answer = event.SessionDescription(type_: "answer", sdp: "v=0 answer")
  should.be_true(webrtc.join_voice(harness.controller, "r1", offer, [], True))
  let _ =
    webrtc.sync_voice(harness.controller, "r1", True, False, False, False, True)
  let _ =
    webrtc.send_ice_candidate(
      harness.controller,
      "r1",
      event.IceCandidateInit(
        candidate: "candidate:1 1 udp 1 10.0.0.2 5000 typ host",
        sdp_mid: Some("0"),
        sdp_m_line_index: Some(0),
        username_fragment: None,
      ),
    )
  let _ = webrtc.send_answer(harness.controller, "r1", answer)
  let _ =
    webrtc.send_renegotiate_offer(harness.controller, "r1", offer, [
      #("1", "camera"),
    ])
  let _ = webrtc.leave_voice(harness.controller, "r1")
  let _ = webrtc.initiate_call(harness.controller, "c1", ["u1", "maya"])
  let _ = webrtc.accept_call(harness.controller, "c1")
  let _ = webrtc.decline_call(harness.controller, "c1")
  let _ = webrtc.cancel_call(harness.controller, "c1")
  let _ = webrtc.leave_call(harness.controller, "c1")
  fake_gateway.wait_messages(harness.server, 11)

  let messages = fake_gateway.messages(harness.server) |> list.map(parsed)
  should.equal(messages, [
    expected_data([
      #("type", dynamic.string("VOICE_JOIN")),
      #(
        "data",
        dynamic.properties([
          #(dynamic.string("room_id"), dynamic.string("r1")),
          #(
            dynamic.string("offer"),
            dynamic.properties([
              #(dynamic.string("type"), dynamic.string("offer")),
              #(dynamic.string("sdp"), dynamic.string("v=0 offer")),
            ]),
          ),
          #(dynamic.string("video_off"), dynamic.bool(True)),
        ]),
      ),
    ]),
    expected_data([
      #("type", dynamic.string("VOICE_SYNC")),
      #("data", dynamic_expected_sync()),
    ]),
    expected_data([
      #("type", dynamic.string("WEBRTC_ICE_CANDIDATE")),
      #("data", dynamic_expected_candidate()),
    ]),
    expected_data([
      #("type", dynamic.string("WEBRTC_ANSWER")),
      #(
        "data",
        dynamic.properties([
          #(dynamic.string("room_id"), dynamic.string("r1")),
          #(
            dynamic.string("answer"),
            dynamic.properties([
              #(dynamic.string("type"), dynamic.string("answer")),
              #(dynamic.string("sdp"), dynamic.string("v=0 answer")),
            ]),
          ),
        ]),
      ),
    ]),
    expected_data([
      #("type", dynamic.string("WEBRTC_RENEGOTIATE_OFFER")),
      #(
        "data",
        dynamic.properties([
          #(dynamic.string("room_id"), dynamic.string("r1")),
          #(
            dynamic.string("offer"),
            dynamic.properties([
              #(dynamic.string("type"), dynamic.string("offer")),
              #(dynamic.string("sdp"), dynamic.string("v=0 offer")),
            ]),
          ),
          #(
            dynamic.string("tracks"),
            dynamic.properties([
              #(dynamic.string("1"), dynamic.string("camera")),
            ]),
          ),
        ]),
      ),
    ]),
    expected_data([
      #("type", dynamic.string("VOICE_LEAVE")),
      #(
        "data",
        dynamic.properties([
          #(dynamic.string("room_id"), dynamic.string("r1")),
        ]),
      ),
    ]),
    expected_data([
      #("type", dynamic.string("CALL_INITIATE")),
      #(
        "data",
        dynamic.properties([
          #(dynamic.string("conversation_id"), dynamic.string("c1")),
          #(
            dynamic.string("member_ids"),
            dynamic.list([dynamic.string("u1"), dynamic.string("maya")]),
          ),
        ]),
      ),
    ]),
    expected_data([
      #("type", dynamic.string("CALL_ACCEPT")),
      #(
        "data",
        dynamic.properties([
          #(dynamic.string("conversation_id"), dynamic.string("c1")),
        ]),
      ),
    ]),
    expected_data([
      #("type", dynamic.string("CALL_DECLINE")),
      #(
        "data",
        dynamic.properties([
          #(dynamic.string("conversation_id"), dynamic.string("c1")),
        ]),
      ),
    ]),
    expected_data([
      #("type", dynamic.string("CALL_CANCEL")),
      #(
        "data",
        dynamic.properties([
          #(dynamic.string("conversation_id"), dynamic.string("c1")),
        ]),
      ),
    ]),
    expected_data([
      #("type", dynamic.string("CALL_LEAVE")),
      #(
        "data",
        dynamic.properties([
          #(dynamic.string("conversation_id"), dynamic.string("c1")),
        ]),
      ),
    ]),
  ])
  close(harness)
}

fn dynamic_expected_sync() -> dynamic.Dynamic {
  dynamic.properties([
    #(dynamic.string("room_id"), dynamic.string("r1")),
    #(dynamic.string("muted"), dynamic.bool(True)),
    #(dynamic.string("deafened"), dynamic.bool(False)),
    #(dynamic.string("screen_sharing"), dynamic.bool(False)),
    #(dynamic.string("camera"), dynamic.bool(False)),
    #(dynamic.string("video_off"), dynamic.bool(True)),
  ])
}

fn dynamic_expected_candidate() -> dynamic.Dynamic {
  dynamic.properties([
    #(dynamic.string("room_id"), dynamic.string("r1")),
    #(
      dynamic.string("candidate"),
      dynamic.properties([
        #(
          dynamic.string("candidate"),
          dynamic.string("candidate:1 1 udp 1 10.0.0.2 5000 typ host"),
        ),
        #(dynamic.string("sdpMid"), dynamic.string("0")),
        #(dynamic.string("sdpMLineIndex"), dynamic.int(0)),
      ]),
    ),
  ])
}

pub fn keeps_the_voice_states_and_passes_on_only_fresh_updates_test() {
  let harness = controlled_gateway()
  let updates = feed.subscribe(webrtc.updates(harness.controller))
  connect(harness)

  fake_gateway.push(
    harness.server,
    "VOICE_STATE_UPDATE",
    "{\"room_id\":\"r1\",\"user_id\":\"maya\",\"joined\":true,\"muted\":false,\"deafened\":false,\"screen_sharing\":false,\"camera\":false,\"version\":5}",
  )
  fake_gateway.push(
    harness.server,
    "VOICE_STATE_UPDATE",
    "{\"room_id\":\"r1\",\"user_id\":\"maya\",\"joined\":false,\"muted\":false,\"deafened\":false,\"screen_sharing\":false,\"camera\":false,\"version\":4}",
  )
  fake_gateway.push(
    harness.server,
    "CALL_INCOMING",
    "{\"conversation_id\":\"c1\",\"initiator_id\":\"maya\",\"initiator_name\":\"Maya\",\"initiator_avatar\":null}",
  )
  let assert Ok(incoming) = events.await_call_incoming(harness.listener, 5000)
  should.equal(incoming.initiator_name, "Maya")
  let assert Ok(update) = events.await_voice_state_update(updates, 5000)
  should.equal(update.version, 5)
  let assert [maya] =
    await_participants(harness.controller, "r1", 5000, fn(people) {
      people != []
    })
  should.equal(maya.user_id, "maya")

  fake_gateway.push(
    harness.server,
    "VOICE_STATE_UPDATE",
    "{\"room_id\":\"c1\",\"user_id\":\"maya\",\"joined\":true,\"muted\":false,\"deafened\":false,\"screen_sharing\":false,\"camera\":false,\"version\":1}",
  )
  fake_gateway.push(
    harness.server,
    "CALL_ENDED",
    "{\"conversation_id\":\"c1\"}",
  )
  let assert Ok(_) = events.await_call_ended(harness.listener, 5000)
  // The gateway sends no leave for a call that ended.
  should.equal(
    await_participants(harness.controller, "c1", 5000, fn(people) {
      people == []
    }),
    [],
  )
  close(harness)
}

pub fn passes_on_calls_placed_and_calls_going_on_test() {
  let harness = controlled_gateway()
  connect(harness)

  fake_gateway.push(
    harness.server,
    "CALL_OUTGOING",
    "{\"conversation_id\":\"c1\"}",
  )
  let assert Ok(outgoing) = events.await_call_outgoing(harness.listener, 5000)
  should.equal(outgoing.conversation_id, "c1")

  fake_gateway.push(
    harness.server,
    "CALL_ONGOING",
    "{\"conversation_id\":\"c2\",\"initiator_id\":\"maya\",\"voice_states\":[{\"user_id\":\"maya\",\"muted\":true,\"version\":3}]}",
  )
  let assert Ok(ongoing) = events.await_call_ongoing(harness.listener, 5000)
  should.equal(ongoing.initiator_id, "maya")
  let assert [maya] =
    await_participants(harness.controller, "c2", 5000, fn(people) {
      people != []
    })
  should.equal(#(maya.user_id, maya.muted, maya.version), #("maya", True, 3))
  close(harness)
}

pub fn silence_before_ready_is_the_gap_before_ready_test() {
  let harness = controlled_gateway()
  connect(harness)
  // The first thing heard: no silence before it.
  should.equal(
    webrtc.silence_before_ready(harness.controller),
    duration.seconds(0),
  )

  process.sleep(300)
  fake_gateway.push(
    harness.server,
    "READY",
    "{\"user\":{\"id\":\"u1\",\"username\":\"gaby\",\"created_at\":\"2026-10-23T09:00:00Z\",\"updated_at\":\"2026-10-23T09:00:00Z\"},\"sessionToken\":\"session-2\"}",
  )
  // What the gateway sends right after READY doesn't change it.
  fake_gateway.push(
    harness.server,
    "CALL_ENDED",
    "{\"conversation_id\":\"c9\"}",
  )
  let assert Ok(_) = events.await_ready(harness.listener, 5000)
  let assert Ok(_) = events.await_call_ended(harness.listener, 5000)
  should.be_true(
    duration.compare(
      webrtc.silence_before_ready(harness.controller),
      duration.milliseconds(300),
    )
    != order.Lt,
  )
  close(harness)
}

pub fn passes_on_the_camera_or_screen_the_gateway_refused_test() {
  let harness = controlled_gateway()
  connect(harness)
  fake_gateway.push(
    harness.server,
    "VOICE_VIDEO_REFUSED",
    "{\"room_id\":\"r1\",\"kind\":\"camera\",\"reason\":\"limit\",\"limit\":8}",
  )
  let assert Ok(refused) =
    events.await_voice_video_refused(harness.listener, 5000)
  should.equal(
    #(refused.room_id, refused.kind, refused.reason, refused.limit),
    #("r1", "camera", "limit", Some(8)),
  )
  close(harness)
}

pub fn a_new_socket_has_a_new_number_and_gets_ready_test() {
  let harness = controlled_gateway()
  connect(harness)
  should.equal(webrtc.connection(harness.controller), Some(1))

  fake_gateway.drop(harness.server)
  let assert Ok(second) = events.await_ready(harness.listener, 5000)
  should.equal(second.session_token, "session-2")
  should.equal(webrtc.connection(harness.controller), Some(2))
  close(harness)
}
