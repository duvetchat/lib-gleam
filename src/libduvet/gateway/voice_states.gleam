import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import libduvet/model/event
import libduvet/model/ready

/// A user's voice state in a space's voice room, or in a conversation's call
/// (then `room_id` is the conversation's ID).
pub type VoiceParticipant {
  VoiceParticipant(
    user_id: String,
    room_id: String,
    muted: Bool,
    deafened: Bool,
    screen_sharing: Bool,
    /// Their camera is on.
    camera: Bool,
    /// The state's version.
    version: Int,
    /// Whose screen share they're watching, by user ID: none when nobody's.
    watching: List(String),
  )
}

/// Who's in voice in every room and call a session knows of, kept as the
/// gateway reports it. Updates can arrive out of order: each carries a version
/// that grows with every change, and one older than what's known is dropped.
pub opaque type VoiceStates {
  VoiceStates(subject: Subject(Message))
}

type Message {
  Apply(state: event.VoiceStateEvent, reply: Subject(Bool))
  Reset(calls: List(ready.GatewayReadyActiveCall), reply: Subject(Nil))
  Space(payload: event.GatewaySpaceCreatePayload, reply: Subject(Nil))
  Ongoing(call: event.CallOngoingEvent, reply: Subject(Nil))
  Forget(room_id: String, reply: Subject(Nil))
  Participants(room_id: String, reply: Subject(List(VoiceParticipant)))
  Rooms(reply: Subject(Dict(String, Dict(String, VoiceParticipant))))
}

type State {
  State(
    rooms: Dict(String, Dict(String, VoiceParticipant)),
    versions: Dict(String, Int),
  )
}

pub fn start() -> VoiceStates {
  let ready = process.new_subject()
  let _ =
    process.spawn(fn() {
      let subject = process.new_subject()
      process.send(ready, subject)
      loop(State(rooms: dict.new(), versions: dict.new()), subject)
    })
  VoiceStates(process.receive_forever(ready))
}

/// Everyone in voice, by room (or call) ID, then by user ID.
pub fn rooms(
  states: VoiceStates,
) -> Dict(String, Dict(String, VoiceParticipant)) {
  ask(states, Rooms)
}

/// Who's in [room_id]: none when nobody is.
pub fn participants_in(
  states: VoiceStates,
  room_id: String,
) -> List(VoiceParticipant) {
  ask(states, fn(reply) { Participants(room_id, reply) })
}

/// READY: a new session, so what was known is dropped, and READY's calls are
/// taken.
pub fn reset(
  states: VoiceStates,
  calls: List(ready.GatewayReadyActiveCall),
) -> Nil {
  ask(states, fn(reply) { Reset(calls, reply) })
}

/// SPACE_CREATE: the space's voice rooms as the gateway has them now replace
/// what was known of them.
pub fn space(
  states: VoiceStates,
  payload: event.GatewaySpaceCreatePayload,
) -> Nil {
  ask(states, fn(reply) { Space(payload, reply) })
}

/// CALL_ONGOING: who is in the call's voice as the gateway has it now replaces
/// what was known of it.
pub fn ongoing(states: VoiceStates, call: event.CallOngoingEvent) -> Nil {
  ask(states, fn(reply) { Ongoing(call, reply) })
}

/// A room that's gone, or a call that ended.
pub fn forget(states: VoiceStates, room_id: String) -> Nil {
  ask(states, fn(reply) { Forget(room_id, reply) })
}

/// VOICE_STATE_UPDATE: answers whether it applied, false for one that came
/// after a newer one.
pub fn apply(states: VoiceStates, update: event.VoiceStateEvent) -> Bool {
  ask(states, fn(reply) { Apply(update, reply) })
}

fn ask(states: VoiceStates, message: fn(Subject(a)) -> Message) -> a {
  let reply = process.new_subject()
  process.send(states.subject, message(reply))
  process.receive_forever(reply)
}

fn loop(state: State, subject: Subject(Message)) -> Nil {
  case process.receive_forever(subject) {
    Apply(update, reply) -> {
      let #(state, applied) = apply_update(state, update)
      process.send(reply, applied)
      loop(state, subject)
    }
    Reset(calls, reply) -> {
      let state =
        list.fold(
          calls,
          State(rooms: dict.new(), versions: dict.new()),
          fn(state, call) {
            call_states(state, call.conversation_id, call.voice_states)
          },
        )
      process.send(reply, Nil)
      loop(state, subject)
    }
    Space(payload, reply) -> {
      let state =
        dict.fold(payload.rooms, state, fn(state, room_id, _room) {
          State(..state, rooms: dict.delete(state.rooms, room_id))
        })
      let state = case payload.voice_states {
        Some(states) ->
          list.fold(states, state, fn(state, voice) {
            snapshot(
              state,
              VoiceParticipant(
                user_id: voice.user_id,
                room_id: voice.room_id,
                muted: voice.muted,
                deafened: voice.deafened,
                screen_sharing: voice.screen_sharing,
                camera: voice.camera,
                version: voice.version,
                watching: voice.watching,
              ),
            )
          })
        None -> state
      }
      process.send(reply, Nil)
      loop(state, subject)
    }
    Ongoing(call, reply) -> {
      process.send(reply, Nil)
      loop(call_states(state, call.conversation_id, call.voice_states), subject)
    }
    Forget(room_id, reply) -> {
      process.send(reply, Nil)
      loop(State(..state, rooms: dict.delete(state.rooms, room_id)), subject)
    }
    Participants(room_id, reply) -> {
      let participants = case dict.get(state.rooms, room_id) {
        Ok(users) -> dict.values(users)
        Error(Nil) -> []
      }
      process.send(reply, participants)
      loop(state, subject)
    }
    Rooms(reply) -> {
      process.send(reply, state.rooms)
      loop(state, subject)
    }
  }
}

fn call_states(
  state: State,
  conversation_id: String,
  states: Option(List(ready.CallVoiceState)),
) -> State {
  let state = State(..state, rooms: dict.delete(state.rooms, conversation_id))
  case states {
    Some(states) ->
      list.fold(states, state, fn(state, voice) {
        snapshot(
          state,
          VoiceParticipant(
            user_id: voice.user_id,
            room_id: conversation_id,
            muted: voice.muted,
            deafened: voice.deafened,
            screen_sharing: voice.screen_sharing,
            camera: voice.camera,
            version: voice.version,
            watching: voice.watching,
          ),
        )
      })
    None -> state
  }
}

fn apply_update(state: State, update: event.VoiceStateEvent) -> #(State, Bool) {
  let key = update.room_id <> ":" <> update.user_id
  let last = dict.get(state.versions, key)
  let stale = case last {
    Ok(version) -> update.version < version
    Error(Nil) -> False
  }
  case stale {
    True -> #(state, False)
    False -> {
      let versions = dict.insert(state.versions, key, update.version)
      let participant =
        VoiceParticipant(
          user_id: update.user_id,
          room_id: update.room_id,
          muted: update.muted,
          deafened: update.deafened,
          screen_sharing: update.screen_sharing,
          camera: update.camera,
          version: update.version,
          watching: update.watching,
        )
      let rooms = case update.joined {
        True -> insert_participant(state.rooms, participant)
        False -> remove_participant(state.rooms, update.room_id, update.user_id)
      }
      #(State(rooms: rooms, versions: versions), True)
    }
  }
}

fn snapshot(state: State, participant: VoiceParticipant) -> State {
  let key = participant.room_id <> ":" <> participant.user_id
  let last = dict.get(state.versions, key)
  let stale = case last {
    Ok(version) -> participant.version < version
    Error(Nil) -> False
  }
  case stale {
    True -> state
    False ->
      State(
        rooms: insert_participant(state.rooms, participant),
        versions: dict.insert(state.versions, key, participant.version),
      )
  }
}

fn insert_participant(
  rooms: Dict(String, Dict(String, VoiceParticipant)),
  participant: VoiceParticipant,
) -> Dict(String, Dict(String, VoiceParticipant)) {
  let users = case dict.get(rooms, participant.room_id) {
    Ok(users) -> users
    Error(Nil) -> dict.new()
  }
  dict.insert(
    rooms,
    participant.room_id,
    dict.insert(users, participant.user_id, participant),
  )
}

fn remove_participant(
  rooms: Dict(String, Dict(String, VoiceParticipant)),
  room_id: String,
  user_id: String,
) -> Dict(String, Dict(String, VoiceParticipant)) {
  case dict.get(rooms, room_id) {
    Error(Nil) -> rooms
    Ok(users) -> {
      let users = dict.delete(users, user_id)
      case dict.is_empty(users) {
        True -> dict.delete(rooms, room_id)
        False -> dict.insert(rooms, room_id, users)
      }
    }
  }
}
