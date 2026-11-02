import gleam/bit_array
import gleam/dict
import gleam/dynamic
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleeunit
import gleeunit/should
import libduvet/api_router
import libduvet/error
import libduvet/http/client
import libduvet/http/methods
import libduvet/http/multipart
import libduvet/http/transport
import libduvet/json_value
import libduvet/model/command_option_type
import libduvet/model/decoding
import libduvet/model/embed
import libduvet/model/message
import libduvet/model/message_reference_type
import libduvet/model/message_type
import libduvet/model/rest
import libduvet/model/room_type
import libduvet/model/user_status
import support/cell
import support/mock_transport

pub fn main() -> Nil {
  gleeunit.main()
}

const time = "2026-10-22T10:00:00.123456Z"

fn blocking_reply(
  _request: transport.Request,
) -> Result(transport.Response, transport.ExchangeError) {
  process.sleep_forever()
  Ok(mock_transport.response(200, ""))
}

fn message_json() -> json.Json {
  json.object([
    #("id", json.string("m1")),
    #("room_id", json.string("r1")),
    #("author_id", json.string("u1")),
    #("content", json.string("hi")),
    #("type", json.int(0)),
    #("created_at", json.string(time)),
    #("updated_at", json.string(time)),
  ])
}

fn room_json() -> json.Json {
  json.object([
    #("id", json.string("r1")),
    #("space_id", json.string("s1")),
    #("parent_id", json.null()),
    #("type", json.int(1)),
    #("name", json.string("general")),
    #("description", json.null()),
    #("position", json.int(0)),
    #("nsfw", json.bool(False)),
    #("created_at", json.string(time)),
    #("updated_at", json.string(time)),
  ])
}

fn role_json() -> json.Json {
  json.object([
    #("id", json.string("ro1")),
    #("space_id", json.string("s1")),
    #("name", json.string("mod")),
    #("color_from", json.null()),
    #("color_via", json.null()),
    #("color_to", json.null()),
    #("flags", json.int(0)),
    #("permissions", json.int(8)),
    #("hoisted", json.bool(False)),
    #("position", json.int(1)),
    #("created_at", json.string(time)),
    #("updated_at", json.string(time)),
  ])
}

fn asset_json() -> json.Json {
  json.object([
    #("id", json.string("e1")),
    #("name", json.string("cat")),
    #("space_id", json.string("s1")),
    #("attachment_id", json.string("a1")),
    #("created_at", json.string(time)),
    #("updated_at", json.string(time)),
  ])
}

fn dm_json() -> json.Json {
  json.object([
    #("id", json.string("d1")),
    #("conversation_id", json.string("c1")),
    #("author_id", json.string("u1")),
    #("content", json.string("yo")),
    #("type", json.int(0)),
    #("created_at", json.string(time)),
    #("updated_at", json.string(time)),
  ])
}

fn conversation_json() -> json.Json {
  json.object([
    #("id", json.string("c1")),
    #("type", json.int(1)),
    #("name", json.null()),
    #("owner_id", json.string("u1")),
    #("created_at", json.string(time)),
    #("updated_at", json.string(time)),
    #("deleted_at", json.null()),
    #("members", json.array([], fn(value) { value })),
  ])
}

fn make_client(
  reply,
  token: String,
  session_token: String,
) -> #(client.RestClient, mock_transport.Mock) {
  let mock = mock_transport.start(reply)
  let api =
    client.new(
      mock_transport.transport(mock),
      api_router_default(),
      token,
      session_token,
      20_000,
    )
  #(api, mock)
}

fn api_with(reply) -> #(client.RestClient, mock_transport.Mock) {
  make_client(reply, "tok", "sess")
}

fn api_router_default() -> api_router.ApiRouter {
  api_router.default_router()
}

fn di(value: Int) -> dynamic.Dynamic {
  dynamic.int(value)
}

fn ds(value: String) -> dynamic.Dynamic {
  dynamic.string(value)
}

fn dobj(pairs: List(#(String, dynamic.Dynamic))) -> dynamic.Dynamic {
  dynamic.properties(
    list.map(pairs, fn(pair) { #(dynamic.string(pair.0), pair.1) }),
  )
}

fn dlist(items: List(dynamic.Dynamic)) -> dynamic.Dynamic {
  dynamic.list(items)
}

/// A JSON null as the decoder leaves it, for comparing request bodies.
@external(erlang, "duvet_json_ffi", "null")
fn dnull() -> dynamic.Dynamic

fn error_body(failure: error.DuvetError) -> Option(String) {
  case failure {
    error.ApiError(api_failure) -> api_failure.body
    error.AuthError(auth_failure) -> auth_failure.body
    _ -> None
  }
}

fn object(pairs: List(#(String, dynamic.Dynamic))) -> decoding.Object {
  dict.from_list(pairs)
}

fn file(filename: String, bytes: BitArray) -> multipart.FilePart {
  multipart.FilePart(field: "files", bytes: bytes, filename: filename)
}

fn small_bytes() -> BitArray {
  let assert Ok(bytes) = bit_array.base16_decode("010203")
  bytes
}

@external(erlang, "duvet_json_ffi", "zeroes")
fn zeroes(size: Int) -> BitArray

// ---------------------------------------------------------------------------
// Messages
// ---------------------------------------------------------------------------

pub fn get_messages_pages_back_by_100_test() {
  let #(api, mock) =
    api_with(fn(_) {
      Ok(
        mock_transport.json_response(
          json.array([message_json()], fn(value) { value }),
        ),
      )
    })
  let _ = methods.get_messages(api, "r1", before: Some("m5"), count: 100)
  let assert [request] = mock_transport.sent(mock)
  should.equal(mock_transport.path(request), "/api/rooms/r1/messages")
  should.equal(mock_transport.query(request), [
    #("count", "100"),
    #("before", "m5"),
  ])
}

pub fn history_pages_take_a_count_test() {
  let #(api, mock) =
    api_with(fn(request) {
      case string.starts_with(mock_transport.path(request), "/api/rooms") {
        True ->
          Ok(
            mock_transport.json_response(
              json.array([message_json()], fn(v) { v }),
            ),
          )
        False ->
          Ok(mock_transport.json_response(json.array([dm_json()], fn(v) { v })))
      }
    })
  let _ = methods.get_messages(api, "r1", before: None, count: 1)
  let _ = methods.get_direct_messages(api, "c1", before: None, count: 1)
  let _ = methods.get_direct_messages(api, "c1", before: Some("d0"), count: 100)
  let assert [first, second, third] = mock_transport.sent(mock)
  should.equal(mock_transport.query(first), [#("count", "1")])
  should.equal(
    mock_transport.path(second),
    "/api/users/@me/conversations/c1/messages",
  )
  should.equal(mock_transport.query(second), [#("count", "1")])
  should.equal(mock_transport.query(third), [
    #("count", "100"),
    #("before", "d0"),
  ])
}

pub fn get_messages_after_asks_in_ascending_order_test() {
  let #(api, mock) =
    api_with(fn(_) {
      Ok(
        mock_transport.json_response(json.array([message_json()], fn(v) { v })),
      )
    })
  let _ = methods.get_messages_after(api, "r1", "m5")
  let assert [request] = mock_transport.sent(mock)
  should.equal(mock_transport.query(request), [
    #("count", "100"),
    #("after", "m5"),
    #("order", "asc"),
  ])
}

pub fn send_message_without_files_sends_json_test() {
  let #(api, mock) =
    api_with(fn(_) { Ok(mock_transport.json_response(message_json())) })
  let options = methods.send_message_options()
  let options =
    methods.SendMessageOptions(
      ..options,
      nonce: Some("n1"),
      message_reference: Some(message.MessageReference(
        type_: Some(message_reference_type.reply),
        message_id: Some("m0"),
        room_id: None,
        space_id: None,
        fail_if_not_exists: None,
      )),
      embeds: [
        embed.Embed(
          type_: None,
          provider: None,
          title: Some("T"),
          description: None,
          url: None,
          timestamp: None,
          color: Some(embed.EmbedColor(
            color_from: Some(0xFF0000),
            color_via: None,
            color_to: None,
          )),
          footer: None,
          image: None,
          thumbnail: None,
          video: None,
          author: None,
          fields: Some([embed.EmbedField(name: "a", value: "b", inline: True)]),
        ),
      ],
      sticker_attachment_id: Some("st1"),
    )
  let _ = methods.send_message(api, "r1", "hello", options)
  let assert [request] = mock_transport.sent(mock)
  should.equal(mock_transport.method(request), "POST")
  should.equal(mock_transport.path(request), "/api/rooms/r1/messages")
  should.equal(
    mock_transport.body_json(request),
    Ok(
      object([
        #("content", ds("hello")),
        #("nonce", ds("n1")),
        #(
          "message_reference",
          dobj([#("type", di(0)), #("message_id", ds("m0"))]),
        ),
        #(
          "embeds",
          dlist([
            dobj([
              #("title", ds("T")),
              #("color", dobj([#("color_from", di(0xFF0000))])),
              #(
                "fields",
                dlist([
                  dobj([
                    #("name", ds("a")),
                    #("value", ds("b")),
                    #("inline", dynamic.bool(True)),
                  ]),
                ]),
              ),
            ]),
          ]),
        ),
        #("sticker_attachment_id", ds("st1")),
      ]),
    ),
  )
}

pub fn send_message_with_files_sends_a_multipart_form_test() {
  let #(api, mock) =
    api_with(fn(_) { Ok(mock_transport.json_response(message_json())) })
  let options = methods.send_message_options()
  let options =
    methods.SendMessageOptions(
      ..options,
      nonce: Some("n1"),
      message_reference: Some(message.MessageReference(
        type_: None,
        message_id: Some("m0"),
        room_id: None,
        space_id: None,
        fail_if_not_exists: None,
      )),
      files: [file("cat.png", small_bytes())],
    )
  let _ = methods.send_message(api, "r1", "look", options)
  let assert [request] = mock_transport.sent(mock)
  let assert Ok(content_type) = mock_transport.header(request, "content-type")
  should.be_true(string.starts_with(
    content_type,
    "multipart/form-data; boundary=",
  ))
  let body = mock_transport.body_text(request)
  should.be_true(string.contains(body, "name=\"content\"\r\n\r\nlook"))
  should.be_true(string.contains(body, "name=\"nonce\"\r\n\r\nn1"))
  should.be_true(string.contains(
    body,
    "name=\"message_reference\"\r\n\r\n{\"message_id\":\"m0\"}",
  ))
  should.be_true(string.contains(body, "name=\"files\"; filename=\"cat.png\""))
  should.be_true(string.contains(body, "content-type: image/png"))
  should.be_false(string.contains(body, "name=\"reference\""))
}

pub fn a_reply_that_does_not_mention_its_author_test() {
  let #(api, mock) =
    api_with(fn(request) {
      case string.starts_with(mock_transport.path(request), "/api/rooms") {
        True -> Ok(mock_transport.json_response(message_json()))
        False ->
          Ok(
            mock_transport.json_response(
              json.object([
                #("id", json.string("d1")),
                #("conversation_id", json.string("c1")),
                #("author_id", json.string("u1")),
                #("content", json.string("hi")),
                #("type", json.int(0)),
                #("created_at", json.string(time)),
                #("updated_at", json.string(time)),
              ]),
            ),
          )
      }
    })
  let reply =
    message.MessageReference(
      type_: Some(message_reference_type.reply),
      message_id: Some("m0"),
      room_id: None,
      space_id: None,
      fail_if_not_exists: None,
    )
  let silent = message.AllowedMentions(replied_user: False)
  let loud = message.AllowedMentions(replied_user: True)
  let options = methods.send_message_options()
  let _ =
    methods.send_message(
      api,
      "r1",
      "hi",
      methods.SendMessageOptions(
        ..options,
        message_reference: Some(reply),
        allowed_mentions: Some(silent),
      ),
    )
  let _ =
    methods.send_direct_message(
      api,
      "c1",
      "hi",
      methods.SendMessageOptions(
        ..options,
        message_reference: Some(reply),
        allowed_mentions: Some(loud),
      ),
    )
  let _ =
    methods.send_message(
      api,
      "r1",
      "look",
      methods.SendMessageOptions(
        ..options,
        message_reference: Some(reply),
        allowed_mentions: Some(silent),
        files: [file("cat.png", small_bytes())],
      ),
    )
  let _ =
    methods.send_direct_message(
      api,
      "c1",
      "look",
      methods.SendMessageOptions(
        ..options,
        message_reference: Some(reply),
        allowed_mentions: Some(silent),
        files: [file("cat.png", small_bytes())],
      ),
    )
  let assert [room, dm, room_file, dm_file] = mock_transport.sent(mock)
  should.equal(
    mock_transport.body_json(room),
    Ok(
      object([
        #("content", ds("hi")),
        #(
          "message_reference",
          dobj([#("type", di(0)), #("message_id", ds("m0"))]),
        ),
        #("allowed_mentions", dobj([#("replied_user", dynamic.bool(False))])),
      ]),
    ),
  )
  should.equal(
    mock_transport.path(dm),
    "/api/users/@me/conversations/c1/messages",
  )
  let assert Ok(dm_body) = mock_transport.body_json(dm)
  should.equal(
    decoding.field(dm_body, "allowed_mentions"),
    Some(dobj([#("replied_user", dynamic.bool(True))])),
  )
  list.each([room_file, dm_file], fn(request) {
    should.be_true(string.contains(
      mock_transport.body_text(request),
      "name=\"allowed_mentions\"\r\n\r\n{\"replied_user\":false}",
    ))
  })
  should.equal(
    mock_transport.path(dm_file),
    "/api/users/@me/conversations/c1/messages",
  )
}

pub fn send_voice_note_sends_a_webm_file_of_type_1_test() {
  let #(api, mock) =
    api_with(fn(_) {
      Ok(
        mock_transport.json_response(
          json.object([
            #("id", json.string("m1")),
            #("room_id", json.string("r1")),
            #("author_id", json.string("u1")),
            #("content", json.string("")),
            #("type", json.int(1)),
            #("created_at", json.string(time)),
            #("updated_at", json.string(time)),
          ]),
        ),
      )
    })
  let assert Ok(note) =
    methods.send_voice_note(
      api,
      "r1",
      small_bytes(),
      nonce: Some("n"),
      format: "webm",
    )
  should.equal(note.type_, message_type.voice)
  let assert [request] = mock_transport.sent(mock)
  let body = mock_transport.body_text(request)
  should.be_true(string.contains(body, "name=\"type\"\r\n\r\n1"))
  should.be_true(string.contains(body, "filename=\"voice-note.webm\""))
  should.be_true(string.contains(body, "content-type: audio/webm"))
}

pub fn voice_notes_name_their_format_test() {
  let #(api, mock) =
    api_with(fn(request) {
      case string.starts_with(mock_transport.path(request), "/api/rooms") {
        True ->
          Ok(
            mock_transport.json_response(
              json.object([
                #("id", json.string("m1")),
                #("room_id", json.string("r1")),
                #("author_id", json.string("u1")),
                #("type", json.int(1)),
                #("created_at", json.string(time)),
                #("updated_at", json.string(time)),
              ]),
            ),
          )
        False ->
          Ok(
            mock_transport.json_response(
              json.object([
                #("id", json.string("d1")),
                #("conversation_id", json.string("c1")),
                #("author_id", json.string("u1")),
                #("type", json.int(1)),
                #("created_at", json.string(time)),
                #("updated_at", json.string(time)),
              ]),
            ),
          )
      }
    })
  let _ =
    methods.send_voice_note(
      api,
      "r1",
      small_bytes(),
      nonce: None,
      format: "ogg",
    )
  let assert Ok(dm) =
    methods.send_dm_voice_note(
      api,
      "c1",
      small_bytes(),
      nonce: None,
      format: "m4a",
    )
  should.equal(dm.type_, message_type.voice)
  let assert [room, direct] = mock_transport.sent(mock)
  let room_body = mock_transport.body_text(room)
  should.be_true(string.contains(room_body, "filename=\"voice-note.ogg\""))
  should.be_true(string.contains(room_body, "content-type: audio/ogg"))
  should.equal(
    mock_transport.path(direct),
    "/api/users/@me/conversations/c1/messages",
  )
  let direct_body = mock_transport.body_text(direct)
  should.be_true(string.contains(direct_body, "name=\"type\"\r\n\r\n1"))
  should.be_true(string.contains(direct_body, "filename=\"voice-note.m4a\""))
  should.be_true(string.contains(direct_body, "content-type: audio/mp4"))
}

pub fn a_voice_note_in_another_format_is_refused_before_sending_test() {
  let #(api, mock) =
    api_with(fn(_) { Ok(mock_transport.json_response(message_json())) })
  case
    methods.send_voice_note(
      api,
      "r1",
      small_bytes(),
      nonce: None,
      format: "mp3",
    )
  {
    Error(error.InvalidArgument(_)) -> Nil
    _ -> should.fail()
  }
  should.equal(mock_transport.sent(mock), [])
}

pub fn an_upload_reports_its_progress_in_pieces_test() {
  let #(api, mock) =
    api_with(fn(_) {
      Ok(
        mock_transport.json_response(
          json.object([
            #("id", json.string("d1")),
            #("conversation_id", json.string("c1")),
            #("author_id", json.string("u1")),
            #("content", json.string("look")),
            #("type", json.int(0)),
            #("created_at", json.string(time)),
            #("updated_at", json.string(time)),
          ]),
        ),
      )
    })
  let progress = cell.new([])
  let options = methods.send_message_options()
  let _ =
    methods.send_direct_message(
      api,
      "c1",
      "look",
      methods.SendMessageOptions(
        ..options,
        files: [file("big.bin", zeroes(300 * 1024))],
        on_progress: Some(fn(sent, total) {
          cell.update(progress, fn(values) {
            list.append(values, [#(sent, total)])
          })
        }),
      ),
    )
  let assert [request] = mock_transport.sent(mock)
  let total =
    list.fold(request.body, 0, fn(sum, piece) {
      sum + bit_array.byte_size(piece)
    })
  let values = cell.get(progress)
  should.be_true(list.length(values) > 4)
  should.equal(list.unique(list.map(values, fn(pair) { pair.1 })), [total])
  let #(last_sent, last_total) = case list.reverse(values) {
    [pair, ..] -> pair
    [] -> #(0, 0)
  }
  should.equal(#(last_sent, last_total), #(total, total))
  let sent = list.map(values, fn(pair) { pair.0 })
  let assert [first, ..rest] = sent
  let #(_, rose) =
    list.fold(rest, #(first, True), fn(state, value) {
      let #(previous, ok) = state
      #(value, ok && value > previous)
    })
  should.be_true(rose)
}

pub fn a_cancelled_send_fails_aborted_test() {
  let mock = mock_transport.start(blocking_reply)
  let api =
    client.new(
      mock_transport.transport(mock),
      api_router_default(),
      "tok",
      "",
      20_000,
    )
  let cancel = process.new_subject()
  process.send(cancel, Nil)
  let options = methods.send_message_options()
  case
    methods.send_message(
      api,
      "r1",
      "hi",
      methods.SendMessageOptions(..options, abort: Some(cancel)),
    )
  {
    Error(error.RequestAborted) -> Nil
    _ -> should.fail()
  }
}

pub fn a_request_that_gets_no_answer_fails_timed_out_test() {
  let mock = mock_transport.start(blocking_reply)
  let api =
    client.new(
      mock_transport.transport(mock),
      api_router_default(),
      "tok",
      "",
      100,
    )
  case methods.get_friends(api) {
    Error(error.RequestTimeout(..)) -> Nil
    _ -> should.fail()
  }
}

pub fn update_message_and_delete_message_test() {
  let #(api, mock) =
    api_with(fn(_) { Ok(mock_transport.json_response(message_json())) })
  let _ = methods.update_message(api, "m1", "edited", "r1")
  let _ = methods.delete_message(api, "m1", "r1")
  let assert [patch, delete] = mock_transport.sent(mock)
  should.equal(mock_transport.method(patch), "PATCH")
  should.equal(mock_transport.path(patch), "/api/rooms/r1/messages/m1")
  should.equal(
    mock_transport.body_json(patch),
    Ok(object([#("content", ds("edited"))])),
  )
  should.equal(mock_transport.method(delete), "DELETE")
  should.equal(mock_transport.path(delete), "/api/rooms/r1/messages/m1")
}

pub fn pins_and_threads_test() {
  let #(api, mock) =
    api_with(fn(request) {
      case mock_transport.method(request) {
        "GET" ->
          Ok(
            mock_transport.json_response(
              json.array([message_json()], fn(v) { v }),
            ),
          )
        _ -> Ok(mock_transport.response(200, ""))
      }
    })
  let _ = methods.get_room_pins(api, "r1")
  let _ = methods.pin_room_message(api, "r1", "m1")
  let _ = methods.unpin_room_message(api, "r1", "m1")
  let _ = methods.get_message_thread(api, "r1", "m1")
  should.equal(
    list.map(mock_transport.sent(mock), fn(request) {
      mock_transport.method(request) <> " " <> mock_transport.path(request)
    }),
    [
      "GET /api/rooms/r1/pins",
      "PUT /api/rooms/r1/pins/m1",
      "DELETE /api/rooms/r1/pins/m1",
      "GET /api/rooms/r1/messages/m1/thread",
    ],
  )
}

pub fn search_repeats_each_lists_key_test() {
  let #(api, mock) =
    api_with(fn(_) {
      Ok(
        mock_transport.json_response(
          json.object([
            #("total_results", json.int(1)),
            #("messages", json.array([message_json()], fn(v) { v })),
          ]),
        ),
      )
    })
  let search =
    rest.MessageSearch(
      query: Some("a b"),
      author_ids: ["u1", "u2"],
      mentions: [],
      room_ids: [],
      has: ["link"],
      pinned: Some(False),
      before: Some(decoding.parse_time("2026-01-02T00:00:00Z", "test")),
      after: None,
      cursor: Some("m7"),
    )
  let assert Ok(response) = methods.search_space_messages(api, "s1", search)
  should.equal(response.total_results, 1)
  let assert [found] = response.messages
  should.equal(found.id, "m1")
  let assert [request] = mock_transport.sent(mock)
  should.equal(mock_transport.path(request), "/api/spaces/s1/messages/search")
  should.equal(mock_transport.query(request), [
    #("query", "a b"),
    #("author_id", "u1"),
    #("author_id", "u2"),
    #("has", "link"),
    #("pinned", "false"),
    #("before", "2026-01-02T00:00:00.000Z"),
    #("cursor", "m7"),
  ])
}

pub fn typing_indicators_swallow_failures_test() {
  let #(api, mock) = api_with(fn(_) { Ok(mock_transport.response(500, "")) })
  methods.send_typing_indicator(api, "r1")
  methods.send_recording_indicator(api, "r1")
  should.equal(list.map(mock_transport.sent(mock), mock_transport.path), [
    "/api/rooms/r1/typing",
    "/api/rooms/r1/recording",
  ])
}

pub fn mention_counts_are_read_and_empty_on_failure_test() {
  let #(api, mock) =
    api_with(fn(_) {
      Ok(
        mock_transport.json_response(
          json.object([#("r1", json.int(2)), #("c1", json.int(1))]),
        ),
      )
    })
  should.equal(
    methods.get_mention_counts(api),
    dict.from_list([#("r1", 2), #("c1", 1)]),
  )
  let assert [request] = mock_transport.sent(mock)
  should.equal(mock_transport.path(request), "/api/users/@me/mentions/counts")

  let #(failing, _) = api_with(fn(_) { Ok(mock_transport.response(500, "")) })
  should.equal(methods.get_mention_counts(failing), dict.new())
}

// ---------------------------------------------------------------------------
// Reactions
// ---------------------------------------------------------------------------

pub fn room_reactions_encode_the_emoji_once_test() {
  let #(api, mock) = api_with(fn(_) { Ok(mock_transport.response(200, "")) })
  let _ = methods.add_room_reaction(api, "r1", "m1", "👍", emoji_id: None)
  let _ = methods.remove_room_reaction(api, "r1", "m1", "👍")
  let _ = methods.remove_room_reaction(api, "r1", "m1", "a/b#c")
  let assert [added, removed, escaped] = mock_transport.sent(mock)
  should.equal(mock_transport.method(added), "PUT")
  should.equal(
    mock_transport.path(added),
    "/api/rooms/r1/messages/m1/reactions",
  )
  should.equal(
    mock_transport.body_json(added),
    Ok(object([#("emoji_name", ds("👍")), #("emoji_id", dnull())])),
  )
  should.equal(
    mock_transport.path(removed),
    "/api/rooms/r1/messages/m1/reactions/%F0%9F%91%8D",
  )
  should.equal(
    mock_transport.path(escaped),
    "/api/rooms/r1/messages/m1/reactions/a%2Fb%23c",
  )
}

pub fn conversation_reactions_test() {
  let #(api, mock) = api_with(fn(_) { Ok(mock_transport.response(200, "")) })
  let _ =
    methods.add_conversation_reaction(
      api,
      "c1",
      "m1",
      "cat",
      emoji_id: Some("e1"),
    )
  let _ = methods.remove_conversation_reaction(api, "c1", "m1", "cat")
  let assert [added, removed] = mock_transport.sent(mock)
  should.equal(
    mock_transport.path(added),
    "/api/users/@me/conversations/c1/messages/m1/reactions",
  )
  should.equal(
    mock_transport.body_json(added),
    Ok(object([#("emoji_name", ds("cat")), #("emoji_id", ds("e1"))])),
  )
  should.equal(
    mock_transport.path(removed),
    "/api/users/@me/conversations/c1/messages/m1/reactions/cat",
  )
}

// ---------------------------------------------------------------------------
// Rooms
// ---------------------------------------------------------------------------

pub fn create_room_sends_the_parent_only_when_there_is_one_test() {
  let #(api, mock) =
    api_with(fn(_) { Ok(mock_transport.json_response(room_json())) })
  let _ =
    methods.create_room(api, "s1", "general", room_type.text, parent_id: None)
  let _ =
    methods.create_room(
      api,
      "s1",
      "voice",
      room_type.voice,
      parent_id: Some("cat1"),
    )
  let assert [first, second] = mock_transport.sent(mock)
  should.equal(
    mock_transport.body_json(first),
    Ok(object([#("name", ds("general")), #("type", di(1))])),
  )
  should.equal(
    mock_transport.body_json(second),
    Ok(
      object([
        #("name", ds("voice")),
        #("type", di(2)),
        #("parent_id", ds("cat1")),
      ]),
    ),
  )
}

pub fn update_room_sends_only_what_is_given_test() {
  let #(api, mock) =
    api_with(fn(_) { Ok(mock_transport.json_response(room_json())) })
  let _ =
    methods.update_room(
      api,
      "s1",
      "r1",
      name: Some("x"),
      description: None,
      clear_description: False,
      parent_id: None,
      clear_parent: False,
      position: None,
    )
  let _ =
    methods.update_room(
      api,
      "s1",
      "r1",
      name: None,
      description: None,
      clear_description: True,
      parent_id: None,
      clear_parent: True,
      position: Some(3),
    )
  let assert [first, second] = mock_transport.sent(mock)
  should.equal(mock_transport.method(first), "PATCH")
  should.equal(mock_transport.path(first), "/api/spaces/s1/rooms/r1")
  should.equal(
    mock_transport.body_json(first),
    Ok(object([#("name", ds("x"))])),
  )
  should.equal(
    mock_transport.body_json(second),
    Ok(
      object([
        #("description", dnull()),
        #("parent_id", dnull()),
        #("position", di(3)),
      ]),
    ),
  )
}

pub fn overwrites_and_invites_test() {
  let #(api, mock) =
    api_with(fn(request) {
      case mock_transport.path(request) {
        "/api/spaces/s1/rooms/r1/overwrites" ->
          Ok(
            mock_transport.json_response(
              json.object([
                #("id", json.string("o1")),
                #("room_id", json.string("r1")),
                #("target_id", json.string("ro1")),
                #("target_type", json.int(0)),
                #("allow_flags", json.int(1)),
                #("deny_flags", json.int(2)),
                #("created_at", json.string(time)),
                #("updated_at", json.string(time)),
              ]),
            ),
          )
        "/api/spaces/s1/rooms/r1/invites" ->
          Ok(
            mock_transport.json_response(
              json.object([#("code", json.string("abc"))]),
            ),
          )
        _ -> Ok(mock_transport.response(200, ""))
      }
    })
  let assert Ok(overwrite) =
    methods.upsert_room_overwrite(api, "s1", "r1", "ro1", 0, 1, 2)
  should.equal(overwrite.allow_flags, 1)
  let _ = methods.delete_room_overwrite(api, "s1", "r1", "ro1")
  let assert Ok(code) = methods.create_room_invite(api, "s1", "r1", 3600)
  should.equal(code, "abc")
  let assert [up, delete, invite] = mock_transport.sent(mock)
  should.equal(mock_transport.method(up), "PUT")
  should.equal(
    mock_transport.body_json(up),
    Ok(
      object([
        #("target_id", ds("ro1")),
        #("target_type", di(0)),
        #("allow_flags", di(1)),
        #("deny_flags", di(2)),
      ]),
    ),
  )
  should.equal(
    mock_transport.path(delete),
    "/api/spaces/s1/rooms/r1/overwrites/ro1",
  )
  should.equal(
    mock_transport.body_json(invite),
    Ok(object([#("max_age", di(3600))])),
  )
}

// ---------------------------------------------------------------------------
// Roles
// ---------------------------------------------------------------------------

pub fn create_role_sends_what_is_given_test() {
  let #(api, mock) =
    api_with(fn(_) { Ok(mock_transport.json_response(role_json())) })
  let _ =
    methods.create_role(
      api,
      "s1",
      "mod",
      permissions: Some(8),
      color_from: None,
      color_via: None,
      color_to: None,
      hoisted: Some(True),
    )
  let assert [request] = mock_transport.sent(mock)
  should.equal(
    mock_transport.body_json(request),
    Ok(
      object([
        #("name", ds("mod")),
        #("permissions", di(8)),
        #("hoisted", dynamic.bool(True)),
      ]),
    ),
  )
}

pub fn update_role_clears_colors_only_when_asked_test() {
  let #(api, mock) =
    api_with(fn(_) { Ok(mock_transport.json_response(role_json())) })
  let _ =
    methods.update_role(
      api,
      "s1",
      "ro1",
      name: None,
      permissions: None,
      color_from: Some(5),
      color_via: None,
      color_to: None,
      hoisted: None,
      position: None,
      clear_colors: False,
    )
  let _ =
    methods.update_role(
      api,
      "s1",
      "ro1",
      name: None,
      permissions: None,
      color_from: None,
      color_via: None,
      color_to: None,
      hoisted: None,
      position: None,
      clear_colors: True,
    )
  let assert [first, second] = mock_transport.sent(mock)
  should.equal(
    mock_transport.body_json(first),
    Ok(object([#("color_from", di(5))])),
  )
  should.equal(
    mock_transport.body_json(second),
    Ok(
      object([
        #("color_from", dnull()),
        #("color_via", dnull()),
        #("color_to", dnull()),
        #("clear_colors", dynamic.bool(True)),
      ]),
    ),
  )
}

pub fn member_roles_take_space_role_member_test() {
  let #(api, mock) = api_with(fn(_) { Ok(mock_transport.response(200, "")) })
  let _ = methods.assign_role_to_member(api, "s1", "ro1", "mem1")
  let _ = methods.remove_role_from_member(api, "s1", "ro1", "mem1")
  should.equal(
    list.map(mock_transport.sent(mock), fn(request) {
      mock_transport.method(request) <> " " <> mock_transport.path(request)
    }),
    [
      "PUT /api/spaces/s1/members/mem1/roles/ro1",
      "DELETE /api/spaces/s1/members/mem1/roles/ro1",
    ],
  )
}

// ---------------------------------------------------------------------------
// Emojis and stickers
// ---------------------------------------------------------------------------

pub fn create_emoji_and_sticker_send_the_file_test() {
  let #(api, mock) =
    api_with(fn(_) { Ok(mock_transport.json_response(asset_json())) })
  let sent = cell.new([])
  let on_progress =
    Some(fn(value, _) {
      cell.update(sent, fn(values) { list.append(values, [value]) })
    })
  let _ =
    methods.create_emoji(
      api,
      "s1",
      "cat",
      multipart.FilePart(
        field: "file",
        bytes: small_bytes(),
        filename: "cat.webp",
      ),
      on_progress: on_progress,
    )
  let _ =
    methods.create_sticker(
      api,
      "s1",
      "cat",
      multipart.FilePart(
        field: "file",
        bytes: small_bytes(),
        filename: "cat.webp",
      ),
      on_progress: on_progress,
    )
  should.be_true(list.length(list.filter(cell.get(sent), fn(v) { v > 0 })) >= 2)
  list.each(mock_transport.sent(mock), fn(request) {
    let assert Ok(content_type) = mock_transport.header(request, "content-type")
    should.be_true(string.starts_with(content_type, "multipart/form-data"))
    let body = mock_transport.body_text(request)
    should.be_true(string.contains(body, "name=\"name\"\r\n\r\ncat"))
    should.be_true(string.contains(body, "name=\"file\"; filename=\"cat.webp\""))
    should.be_true(string.contains(body, "content-type: image/webp"))
  })
  should.equal(list.map(mock_transport.sent(mock), mock_transport.path), [
    "/api/spaces/s1/emojis",
    "/api/spaces/s1/stickers",
  ])
}

pub fn list_update_delete_emoji_and_sticker_test() {
  let #(api, mock) =
    api_with(fn(request) {
      case mock_transport.method(request) {
        "GET" ->
          Ok(
            mock_transport.json_response(
              json.array([asset_json()], fn(v) { v }),
            ),
          )
        "PATCH" -> Ok(mock_transport.json_response(asset_json()))
        _ -> Ok(mock_transport.response(200, ""))
      }
    })
  let assert Ok(emojis) = methods.list_emojis(api, "s1")
  should.equal(list.length(emojis), 1)
  let _ = methods.update_sticker(api, "s1", "st1", "dog")
  let _ = methods.delete_sticker(api, "s1", "st1")
  let assert [_, updated, _] = mock_transport.sent(mock)
  should.equal(
    mock_transport.body_json(updated),
    Ok(object([#("name", ds("dog"))])),
  )
  should.equal(
    list.map(mock_transport.sent(mock), fn(request) {
      mock_transport.method(request) <> " " <> mock_transport.path(request)
    }),
    [
      "GET /api/spaces/s1/emojis",
      "PATCH /api/spaces/s1/stickers/st1",
      "DELETE /api/spaces/s1/stickers/st1",
    ],
  )
}

// ---------------------------------------------------------------------------
// Spaces
// ---------------------------------------------------------------------------

fn created_space_json() -> json.Json {
  json.object([
    #(
      "space",
      json.object([
        #("id", json.string("s1")),
        #("name", json.string("S")),
        #("owner_id", json.string("u1")),
        #("created_at", json.string(time)),
        #("updated_at", json.string(time)),
      ]),
    ),
    #("role", role_json()),
    #("text_room", room_json()),
    #(
      "voice_room",
      json.object([
        #("id", json.string("r2")),
        #("space_id", json.string("s1")),
        #("parent_id", json.null()),
        #("type", json.int(2)),
        #("name", json.string("general")),
        #("description", json.null()),
        #("position", json.int(0)),
        #("nsfw", json.bool(False)),
        #("created_at", json.string(time)),
        #("updated_at", json.string(time)),
      ]),
    ),
    #(
      "member",
      json.object([
        #("id", json.string("mem1")),
        #("space_id", json.string("s1")),
        #("user_id", json.string("u1")),
        #("created_at", json.string(time)),
        #("updated_at", json.string(time)),
      ]),
    ),
  ])
}

pub fn create_space_answers_the_space_and_its_rooms_test() {
  let #(api, mock) =
    api_with(fn(_) { Ok(mock_transport.json_response(created_space_json())) })
  let assert Ok(space) = methods.create_space(api, "S", description: None)
  let _ = methods.create_space(api, "S", description: Some("d"))
  let assert [first, second] = mock_transport.sent(mock)
  should.equal(mock_transport.method(first), "POST")
  should.equal(mock_transport.path(first), "/api/spaces")
  should.equal(
    mock_transport.body_json(first),
    Ok(object([#("name", ds("S"))])),
  )
  should.equal(
    mock_transport.body_json(second),
    Ok(object([#("name", ds("S")), #("description", ds("d"))])),
  )
  should.equal(rest.created_space_id(space), "s1")
  should.equal(space.space.owner_id, "u1")
  should.equal(list.map(space.rooms, fn(room) { #(room.id, room.type_) }), [
    #("r1", room_type.text),
    #("r2", room_type.voice),
  ])
}

pub fn delete_space_test() {
  let #(api, mock) = api_with(fn(_) { Ok(mock_transport.response(204, "")) })
  let _ = methods.delete_space(api, "s1")
  let assert [request] = mock_transport.sent(mock)
  should.equal(mock_transport.method(request), "DELETE")
  should.equal(mock_transport.path(request), "/api/spaces/s1")
}

pub fn delete_space_refusals_keep_their_status_and_body_test() {
  list.each(
    [
      #(403, "{\"error\":\"only the space's owner can delete it\"}"),
      #(404, "{\"error\":\"space not found\"}"),
      #(404, "404 page not found"),
    ],
    fn(entry) {
      let #(status, body) = entry
      let #(api, _) =
        api_with(fn(_) { Ok(mock_transport.response(status, body)) })
      case methods.delete_space(api, "s1") {
        Error(failure) -> {
          should.equal(error.status_code(failure), Some(status))
          should.equal(error_body(failure), Some(body))
        }
        Ok(_) -> should.fail()
      }
    },
  )
}

pub fn update_space_sends_json_or_a_form_for_images_test() {
  let #(api, mock) =
    api_with(fn(_) {
      Ok(
        mock_transport.json_response(json.object([#("id", json.string("s1"))])),
      )
    })
  let _ =
    methods.update_space(
      api,
      "s1",
      name: Some("N"),
      description: None,
      locale: None,
      banner: None,
      icon: None,
      remove_banner: False,
      remove_icon: False,
      on_progress: None,
    )
  let progress = cell.new([])
  let _ =
    methods.update_space(
      api,
      "s1",
      name: None,
      description: None,
      locale: None,
      banner: None,
      icon: None,
      remove_banner: False,
      remove_icon: True,
      on_progress: Some(fn(sent, total) {
        cell.update(progress, fn(_) { [#(sent, total)] })
      }),
    )
  let assert [first, second] = mock_transport.sent(mock)
  let total =
    list.fold(second.body, 0, fn(sum, piece) {
      sum + bit_array.byte_size(piece)
    })
  should.equal(cell.get(progress), [#(total, total)])
  should.equal(
    mock_transport.body_json(first),
    Ok(object([#("name", ds("N"))])),
  )
  let assert Ok(content_type) = mock_transport.header(second, "content-type")
  should.be_true(string.starts_with(content_type, "multipart/form-data"))
  should.be_true(string.contains(
    mock_transport.body_text(second),
    "name=\"remove_icon\"\r\n\r\ntrue",
  ))
}

pub fn members_are_paged_by_highest_role_and_id_test() {
  let #(api, mock) =
    api_with(fn(_) {
      Ok(mock_transport.json_response(json.array([], fn(v) { v })))
    })
  let _ = methods.get_space_members(api, "s1", after_id: None, after_pos: None)
  let _ =
    methods.get_space_members(
      api,
      "s1",
      after_id: Some("mem9"),
      after_pos: Some(2),
    )
  let assert [first, second] = mock_transport.sent(mock)
  should.equal(mock_transport.query(first), [#("count", "50")])
  should.equal(mock_transport.query(second), [
    #("count", "50"),
    #("after_id", "mem9"),
    #("after_pos", "2"),
  ])
}

// ---------------------------------------------------------------------------
// Friends
// ---------------------------------------------------------------------------

pub fn friend_paths_test() {
  let #(api, mock) =
    api_with(fn(request) {
      case mock_transport.method(request), mock_transport.path(request) {
        "POST", "/api/users/@me/friends/requests" ->
          Ok(
            mock_transport.json_response(
              json.object([
                #("id", json.string("fr1")),
                #("sender_id", json.string("u1")),
                #("recipient_id", json.string("u2")),
                #("created_at", json.string(time)),
                #("updated_at", json.string(time)),
              ]),
            ),
          )
        "POST", _ ->
          Ok(
            mock_transport.json_response(
              json.object([
                #("id", json.string("f1")),
                #("request_id", json.string("fr1")),
                #("sender_id", json.string("u1")),
                #("recipient_id", json.string("u2")),
                #("user_username", json.string("bob")),
                #("user_alias", json.null()),
                #("user_avatar", json.null()),
              ]),
            ),
          )
        "GET", _ ->
          Ok(mock_transport.json_response(json.array([], fn(v) { v })))
        _, _ -> Ok(mock_transport.response(200, ""))
      }
    })
  let assert Ok(request) = methods.send_friend_request(api, "u2")
  should.equal(request.user_username, None)
  let _ = methods.get_pending_requests(api)
  let _ = methods.get_sent_requests(api)
  let assert Ok(friend) = methods.accept_friend_request(api, "fr1")
  should.equal(friend.user_username, "bob")
  let _ = methods.reject_friend_request(api, "fr1")
  let _ = methods.get_friends(api)
  let _ = methods.unfriend(api, "u2")
  let assert [first, ..] = mock_transport.sent(mock)
  should.equal(
    mock_transport.body_json(first),
    Ok(object([#("user_id", ds("u2"))])),
  )
  should.equal(
    list.map(mock_transport.sent(mock), fn(request) {
      mock_transport.method(request) <> " " <> mock_transport.path(request)
    }),
    [
      "POST /api/users/@me/friends/requests",
      "GET /api/users/@me/friends/requests",
      "GET /api/users/@me/friends/requests/sent",
      "POST /api/users/@me/friends/requests/fr1/accept",
      "DELETE /api/users/@me/friends/requests/fr1",
      "GET /api/users/@me/friends",
      "DELETE /api/users/@me/friends/u2",
    ],
  )
}

// ---------------------------------------------------------------------------
// Conversations
// ---------------------------------------------------------------------------

pub fn create_dms_and_groups_test() {
  let #(api, mock) =
    api_with(fn(_) { Ok(mock_transport.json_response(conversation_json())) })
  let _ = methods.create_dm(api, "u2")
  let _ = methods.create_group(api, "G", ["u2", "u3"])
  let assert [dm, group] = mock_transport.sent(mock)
  should.equal(
    mock_transport.body_json(dm),
    Ok(object([#("type", di(1)), #("user_id", ds("u2"))])),
  )
  should.equal(
    mock_transport.body_json(group),
    Ok(
      object([
        #("type", di(2)),
        #("name", ds("G")),
        #("user_ids", dlist([ds("u2"), ds("u3")])),
      ]),
    ),
  )
}

pub fn conversation_messages_test() {
  let #(api, mock) =
    api_with(fn(request) {
      case mock_transport.method(request) {
        "GET" ->
          Ok(mock_transport.json_response(json.array([dm_json()], fn(v) { v })))
        _ -> Ok(mock_transport.json_response(dm_json()))
      }
    })
  let _ = methods.get_direct_messages(api, "c1", before: Some("d0"), count: 100)
  let _ = methods.get_direct_messages_after(api, "c1", "d0")
  let _ =
    methods.send_direct_message(
      api,
      "c1",
      "yo",
      methods.SendMessageOptions(
        ..methods.send_message_options(),
        nonce: Some("n"),
      ),
    )
  let _ = methods.update_direct_message(api, "c1", "d1", "edit")
  let assert [page, after, sent, updated] = mock_transport.sent(mock)
  should.equal(
    mock_transport.path(page),
    "/api/users/@me/conversations/c1/messages",
  )
  should.equal(mock_transport.query(page), [
    #("count", "100"),
    #("before", "d0"),
  ])
  should.equal(
    mock_transport.path(after),
    "/api/users/@me/conversations/c1/messages/after",
  )
  should.equal(mock_transport.query(after), [
    #("count", "100"),
    #("after", "d0"),
  ])
  should.equal(
    mock_transport.body_json(sent),
    Ok(object([#("content", ds("yo")), #("nonce", ds("n"))])),
  )
  should.equal(
    mock_transport.body_json(updated),
    Ok(object([#("content", ds("edit"))])),
  )
}

pub fn a_messages_thread_test() {
  let #(api, mock) =
    api_with(fn(_) {
      Ok(
        mock_transport.json_response(
          json.array(
            [
              dm_json(),
              json.object([
                #("id", json.string("d2")),
                #("conversation_id", json.string("c1")),
                #("author_id", json.string("u1")),
                #("type", json.int(0)),
                #("ref_message_id", json.string("d1")),
                #("created_at", json.string(time)),
                #("updated_at", json.string(time)),
              ]),
            ],
            fn(v) { v },
          ),
        ),
      )
    })
  let assert Ok(thread) =
    methods.get_conversation_message_thread(api, "c1", "d1")
  let assert [request] = mock_transport.sent(mock)
  should.equal(mock_transport.method(request), "GET")
  should.equal(
    mock_transport.path(request),
    "/api/users/@me/conversations/c1/messages/d1/thread",
  )
  should.equal(list.map(thread, fn(item) { item.id }), ["d1", "d2"])
}

pub fn conversation_members_pins_and_typing_test() {
  let #(api, mock) = api_with(fn(_) { Ok(mock_transport.response(200, "")) })
  let _ = methods.remove_conversation_member(api, "c1", "u2")
  let _ = methods.leave_conversation(api, "c1")
  let _ = methods.pin_conversation_message(api, "c1", "d1")
  let _ = methods.send_conversation_typing(api, "c1")
  let _ = methods.send_conversation_recording(api, "c1")
  should.equal(
    list.map(mock_transport.sent(mock), fn(request) {
      mock_transport.method(request) <> " " <> mock_transport.path(request)
    }),
    [
      "DELETE /api/users/@me/conversations/c1/members/u2",
      "DELETE /api/users/@me/conversations/c1/members/@me",
      "PUT /api/users/@me/conversations/c1/pins/d1",
      "POST /api/users/@me/conversations/c1/typing",
      "POST /api/users/@me/conversations/c1/recording",
    ],
  )
}

// ---------------------------------------------------------------------------
// Interactions
// ---------------------------------------------------------------------------

pub fn component_and_command_uses_test() {
  let #(api, mock) =
    api_with(fn(_) {
      Ok(mock_transport.json_response(json.object([#("type", json.int(4))])))
    })
  let assert Ok(component_type) =
    methods.use_component(
      api,
      "r1",
      "m1",
      rest.ComponentUse(custom_id: "b", component_type: 2, values: None),
    )
    |> result.map(fn(reply) { reply.type_ })
  should.equal(component_type, 4)
  let _ =
    methods.use_command(
      api,
      "r1",
      "app1",
      rest.CommandUse(id: "cmd1", name: "roll", options: [
        rest.UsedOption(
          name: "sides",
          type_: command_option_type.integer,
          value: json_value.JsonInt(6),
        ),
      ]),
    )
  let assert [component, command] = mock_transport.sent(mock)
  should.equal(mock_transport.path(component), "/api/interactions")
  should.equal(
    mock_transport.body_json(component),
    Ok(
      object([
        #("type", di(3)),
        #("room_id", ds("r1")),
        #("message_id", ds("m1")),
        #("data", dobj([#("custom_id", ds("b")), #("component_type", di(2))])),
      ]),
    ),
  )
  should.equal(
    mock_transport.body_json(command),
    Ok(
      object([
        #("type", di(2)),
        #("room_id", ds("r1")),
        #("application_id", ds("app1")),
        #(
          "data",
          dobj([
            #("id", ds("cmd1")),
            #("name", ds("roll")),
            #("type", di(1)),
            #(
              "options",
              dlist([
                dobj([
                  #("name", ds("sides")),
                  #("type", di(4)),
                  #("value", di(6)),
                ]),
              ]),
            ),
          ]),
        ),
      ]),
    ),
  )
}

pub fn a_use_answers_the_modal_the_bot_opened_test() {
  let #(api, mock) =
    api_with(fn(request) {
      let assert Ok(body) = mock_transport.body_json(request)
      case decoding.int_or(body, "type", 0) {
        3 ->
          Ok(
            mock_transport.json_response(
              json.object([
                #("type", json.int(9)),
                #(
                  "data",
                  json.object([
                    #("custom_id", json.string("feedback")),
                    #("title", json.string("Feedback")),
                    #(
                      "components",
                      json.array(
                        [
                          json.object([
                            #("type", json.int(18)),
                            #("label", json.string("What happened?")),
                          ]),
                        ],
                        fn(v) { v },
                      ),
                    ),
                  ]),
                ),
                #("application_id", json.string("app1")),
              ]),
            ),
          )
        _ ->
          Ok(
            mock_transport.json_response(json.object([#("type", json.int(5))])),
          )
      }
    })
  let assert Ok(opened) =
    methods.use_component(
      api,
      "r1",
      "m1",
      rest.ComponentUse(custom_id: "b", component_type: 2, values: None),
    )
  should.be_true(rest.interaction_reply_is_modal(opened))
  let assert Some(modal) = opened.modal
  should.equal(decoding.string(modal, "custom_id"), "feedback")
  should.equal(opened.application_id, Some("app1"))
  let assert Ok(deferred) =
    methods.use_command(
      api,
      "r1",
      "app1",
      rest.CommandUse(id: "cmd1", name: "roll", options: []),
    )
  should.equal(#(deferred.type_, rest.interaction_reply_is_modal(deferred)), #(
    5,
    False,
  ))
  let assert [component, command] = mock_transport.sent(mock)
  should.equal(
    mock_transport.body_json(component),
    Ok(
      object([
        #("type", di(3)),
        #("room_id", ds("r1")),
        #("message_id", ds("m1")),
        #("data", dobj([#("custom_id", ds("b")), #("component_type", di(2))])),
      ]),
    ),
  )
  should.equal(
    mock_transport.body_json(command),
    Ok(
      object([
        #("type", di(2)),
        #("room_id", ds("r1")),
        #("application_id", ds("app1")),
        #(
          "data",
          dobj([
            #("id", ds("cmd1")),
            #("name", ds("roll")),
            #("type", di(1)),
            #("options", dlist([])),
          ]),
        ),
      ]),
    ),
  )
}

pub fn submit_modal_sends_the_modals_answers_test() {
  let #(api, mock) =
    api_with(fn(_) {
      Ok(mock_transport.json_response(json.object([#("type", json.int(4))])))
    })
  let answers = [
    object([
      #("type", di(18)),
      #("id", di(1)),
      #(
        "component",
        dobj([
          #("type", di(4)),
          #("custom_id", ds("why")),
          #("value", ds("it broke")),
        ]),
      ),
    ]),
  ]
  let assert Ok(reply) =
    methods.submit_modal(
      api,
      "r1",
      "app1",
      "feedback",
      answers,
      message_id: Some("m1"),
    )
  let _ =
    methods.submit_modal(
      api,
      "r1",
      "app1",
      "feedback",
      answers,
      message_id: None,
    )
  should.equal(reply.type_, 4)
  let assert [with_message, without] = mock_transport.sent(mock)
  should.equal(mock_transport.path(with_message), "/api/interactions")
  should.equal(
    mock_transport.body_json(with_message),
    Ok(
      object([
        #("type", di(5)),
        #("room_id", ds("r1")),
        #("application_id", ds("app1")),
        #("message_id", ds("m1")),
        #(
          "data",
          dobj([
            #("custom_id", ds("feedback")),
            #(
              "components",
              dlist([
                dobj([
                  #("type", di(18)),
                  #("id", di(1)),
                  #(
                    "component",
                    dobj([
                      #("type", di(4)),
                      #("custom_id", ds("why")),
                      #("value", ds("it broke")),
                    ]),
                  ),
                ]),
              ]),
            ),
          ]),
        ),
      ]),
    ),
  )
  let assert Ok(body) = mock_transport.body_json(without)
  should.equal(decoding.field(body, "message_id"), None)
}

pub fn a_failed_command_use_forgets_the_space_commands_test() {
  let fail = cell.new(False)
  let #(api, mock) =
    api_with(fn(request) {
      case mock_transport.method(request) {
        "GET" ->
          Ok(
            mock_transport.json_response(
              json.object([
                #("applications", json.array([], fn(v) { v })),
                #("commands", json.array([], fn(v) { v })),
              ]),
            ),
          )
        _ ->
          case cell.get(fail) {
            True ->
              Ok(mock_transport.response(404, "{\"error\":\"unknown command\"}"))
            False ->
              Ok(
                mock_transport.json_response(
                  json.object([#("type", json.int(4))]),
                ),
              )
          }
      }
    })
  let _ = methods.get_space_commands(api, "s1")
  let _ =
    methods.use_command(
      api,
      "r1",
      "app1",
      rest.CommandUse(id: "c", name: "x", options: []),
    )
  let _ = methods.get_space_commands(api, "s1")
  should.equal(
    list.length(
      list.filter(mock_transport.sent(mock), fn(request) {
        mock_transport.method(request) == "GET"
      }),
    ),
    1,
  )
  cell.update(fail, fn(_) { True })
  case
    methods.use_command(
      api,
      "r1",
      "app1",
      rest.CommandUse(id: "c", name: "x", options: []),
    )
  {
    Error(error.ApiError(_)) -> Nil
    _ -> should.fail()
  }
  let _ = methods.get_space_commands(api, "s1")
  should.equal(
    list.length(
      list.filter(mock_transport.sent(mock), fn(request) {
        mock_transport.method(request) == "GET"
      }),
    ),
    2,
  )
}

pub fn space_commands_are_cached_and_a_failed_list_is_not_test() {
  let fail = cell.new(True)
  let #(api, mock) =
    api_with(fn(_) {
      case cell.get(fail) {
        True -> Ok(mock_transport.response(500, ""))
        False ->
          Ok(
            mock_transport.json_response(
              json.object([
                #("applications", json.array([], fn(v) { v })),
                #("commands", json.array([], fn(v) { v })),
              ]),
            ),
          )
      }
    })
  case methods.get_space_commands(api, "s1") {
    Error(error.ApiError(_)) -> Nil
    _ -> should.fail()
  }
  cell.update(fail, fn(_) { False })
  let _ = methods.get_space_commands(api, "s1")
  let _ = methods.get_space_commands(api, "s1")
  should.equal(list.length(mock_transport.sent(mock)), 2)
  methods.forget_space_commands(api, "s1")
  let _ = methods.get_space_commands(api, "s1")
  should.equal(list.length(mock_transport.sent(mock)), 3)
}

// ---------------------------------------------------------------------------
// Users
// ---------------------------------------------------------------------------

fn user_me_json() -> json.Json {
  json.object([
    #("id", json.string("u1")),
    #("username", json.string("me")),
    #("email", json.string("a@b.c")),
    #("email_verified", json.bool(True)),
    #("alias", json.null()),
    #("birthdate", json.null()),
    #("phone", json.null()),
    #("avatar", json.null()),
    #("banner", json.null()),
    #("custom", json.string("")),
    #("created_at", json.string(time)),
    #("updated_at", json.string(time)),
  ])
}

pub fn update_user_sends_only_what_is_given_test() {
  let #(api, mock) =
    api_with(fn(_) { Ok(mock_transport.json_response(user_me_json())) })
  let _ =
    methods.update_user(
      api,
      username: Some("me"),
      alias: None,
      clear_alias: False,
      avatar: None,
      clear_avatar: False,
      banner: None,
      clear_banner: False,
      custom: None,
    )
  let _ =
    methods.update_user(
      api,
      username: None,
      alias: None,
      clear_alias: True,
      avatar: None,
      clear_avatar: False,
      banner: None,
      clear_banner: False,
      custom: None,
    )
  let _ =
    methods.update_user(
      api,
      username: None,
      alias: Some("Me"),
      clear_alias: False,
      avatar: None,
      clear_avatar: False,
      banner: None,
      clear_banner: False,
      custom: Some("Hi 👋"),
    )
  let _ =
    methods.update_user(
      api,
      username: None,
      alias: None,
      clear_alias: False,
      avatar: None,
      clear_avatar: False,
      banner: None,
      clear_banner: False,
      custom: Some(""),
    )
  let _ =
    methods.update_user(
      api,
      username: None,
      alias: None,
      clear_alias: False,
      avatar: None,
      clear_avatar: True,
      banner: None,
      clear_banner: False,
      custom: None,
    )
  let _ =
    methods.update_user(
      api,
      username: None,
      alias: None,
      clear_alias: False,
      avatar: None,
      clear_avatar: False,
      banner: None,
      clear_banner: True,
      custom: None,
    )
  let _ =
    methods.update_user(
      api,
      username: None,
      alias: None,
      clear_alias: False,
      avatar: Some("a.png"),
      clear_avatar: False,
      banner: Some("b.png"),
      clear_banner: False,
      custom: None,
    )
  let bodies =
    mock_transport.sent(mock)
    |> list.map(mock_transport.body_json)
  should.equal(bodies, [
    Ok(object([#("username", ds("me"))])),
    Ok(object([#("alias", dnull())])),
    Ok(object([#("alias", ds("Me")), #("custom", ds("Hi 👋"))])),
    Ok(object([#("custom", ds(""))])),
    Ok(object([#("avatar", dnull())])),
    Ok(object([#("banner", dnull())])),
    Ok(object([#("avatar", ds("a.png")), #("banner", ds("b.png"))])),
  ])
}

pub fn set_status_chooses_online_or_do_not_disturb_test() {
  let #(api, mock) =
    api_with(fn(_) {
      Ok(
        mock_transport.json_response(
          json.object([
            #("id", json.string("u1")),
            #("username", json.string("me")),
            #("email_verified", json.bool(True)),
            #("custom", json.string("")),
            #("status", json.int(2)),
            #("created_at", json.string(time)),
            #("updated_at", json.string(time)),
          ]),
        ),
      )
    })
  let assert Ok(me) = methods.set_status(api, user_status.dnd)
  let _ = methods.set_status(api, user_status.online)
  let assert [dnd, online] = mock_transport.sent(mock)
  should.equal(mock_transport.method(dnd), "PUT")
  should.equal(mock_transport.path(dnd), "/api/users/@me/status")
  should.equal(mock_transport.body_json(dnd), Ok(object([#("status", di(2))])))
  should.equal(
    mock_transport.body_json(online),
    Ok(object([#("status", di(1))])),
  )
  should.equal(me.status, Some(user_status.dnd))
  // Offline isn't a choice: nothing is sent.
  case methods.set_status(api, user_status.offline) {
    Error(error.InvalidArgument(_)) -> Nil
    _ -> should.fail()
  }
  should.equal(list.length(mock_transport.sent(mock)), 2)
}

pub fn set_status_a_bots_refusal_keeps_its_status_and_body_test() {
  let body = "{\"error\":\"bots cannot access this endpoint\"}"
  let #(api, _) = api_with(fn(_) { Ok(mock_transport.response(403, body)) })
  case methods.set_status(api, user_status.dnd) {
    Error(error.AuthError(failure)) -> {
      should.equal(failure.status_code, 403)
      should.equal(failure.body, Some(body))
    }
    _ -> should.fail()
  }
}

pub fn upload_profile_image_sends_the_image_alone_test() {
  let #(api, mock) = api_with(fn(_) { Ok(mock_transport.response(500, "")) })
  let progress = cell.new([])
  case
    methods.upload_profile_image(
      api,
      methods.Avatar,
      small_bytes(),
      "me.jpg",
      on_progress: Some(fn(sent, total) {
        cell.update(progress, fn(_) { [#(sent, total)] })
      }),
    )
  {
    Error(error.ApiError(_)) -> Nil
    _ -> should.fail()
  }
  let assert [request] = mock_transport.sent(mock)
  let body = mock_transport.body_text(request)
  should.be_false(string.contains(body, "_crop_"))
  let total =
    list.fold(request.body, 0, fn(sum, piece) {
      sum + bit_array.byte_size(piece)
    })
  should.equal(cell.get(progress), [#(total, total)])
  should.be_true(string.contains(body, "name=\"avatar\"; filename=\"me.jpg\""))
  should.be_true(string.contains(body, "content-type: image/jpeg"))
}
// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
