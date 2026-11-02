import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import libduvet/error.{type DuvetError, MalformedMessage}
import libduvet/http/client
import libduvet/http/core
import libduvet/http/transport
import libduvet/json_value

// ---------------------------------------------------------------------------
// The endpoints a bot calls with its own token.
//
// A bot's token authenticates it (`client.new_bot`), so these take a
// `RestClient` made by that constructor. Bodies and answers stay JSON: a bot
// sends components and reads interactions as they came, and this package
// doesn't get between it and the wire.
// ---------------------------------------------------------------------------

/// The calling bot's application, with the team its commands live under.
pub fn get_application(
  client: client.RestClient,
) -> Result(json.Json, DuvetError) {
  request_json(
    client,
    "GET",
    "/api/applications/@me",
    "get bot application",
    core.NoBody,
    client.default_meta(client),
  )
  |> result.try(expect_json("the API answered no application for the bot"))
}

/// The bot's next interaction, waiting up to 20 seconds for one; `wait_short`
/// waits 3, for a poll that keeps a request short. `None` when none came.
pub fn next_interaction(
  client: client.RestClient,
  application_id: String,
  wait_short: Bool,
) -> Result(Option(json.Json), DuvetError) {
  let meta = client.default_meta(client)
  let meta = case wait_short {
    True -> core.with_query(meta, [#("wait", "short")])
    False -> meta
  }
  request_json(
    client,
    "GET",
    "/api/applications/" <> application_id <> "/interactions/next",
    "get next interaction",
    core.NoBody,
    meta,
  )
}

/// The bot's first response to an interaction, with its token: `type` is a
/// callback type (4 a message, 5 a deferred one, 6 a deferred update, 7 an
/// update, 9 a modal). `with_response` asks for the message it made.
pub fn respond(
  client: client.RestClient,
  interaction_id: String,
  token: String,
  type_: Int,
  data: Option(json.Json),
  with_response: Bool,
) -> Result(Option(json.Json), DuvetError) {
  let meta = client.default_meta(client)
  let meta = case with_response {
    True -> core.with_query(meta, [#("with_response", "true")])
    False -> meta
  }
  let body =
    core.JsonBody(
      json.object(
        list.flatten([
          [#("type", json.int(type_))],
          case data {
            Some(value) -> [#("data", value)]
            None -> []
          },
        ]),
      ),
    )
  request_json(
    client,
    "POST",
    "/api/interactions/" <> interaction_id <> "/" <> token <> "/callback",
    "respond to interaction",
    body,
    meta,
  )
}

/// A follow-up of an interaction: a message after its first response, with
/// the interaction's token (the application's ID stands where a webhook's
/// does).
pub fn follow_up(
  client: client.RestClient,
  application_id: String,
  token: String,
  message: json.Json,
) -> Result(json.Json, DuvetError) {
  request_json(
    client,
    "POST",
    "/api/webhooks/" <> application_id <> "/" <> token,
    "send interaction follow-up",
    core.JsonBody(message),
    client.default_meta(client),
  )
  |> result.try(expect_json("the API answered no follow-up"))
}

/// `@original`, or a follow-up of the interaction, as a message.
pub fn get_message(
  client: client.RestClient,
  application_id: String,
  token: String,
  message_ref: String,
) -> Result(json.Json, DuvetError) {
  request_json(
    client,
    "GET",
    message_path(application_id, token, message_ref),
    "get interaction message",
    core.NoBody,
    client.default_meta(client),
  )
  |> result.try(expect_json("the API answered no interaction message"))
}

/// Edits `@original` (which completes a deferred response), or a follow-up.
pub fn edit_message(
  client: client.RestClient,
  application_id: String,
  token: String,
  message_ref: String,
  message: json.Json,
) -> Result(Nil, DuvetError) {
  request_void(
    client,
    "PATCH",
    message_path(application_id, token, message_ref),
    "edit interaction message",
    core.JsonBody(message),
  )
}

/// Deletes `@original`, or a follow-up.
pub fn delete_message(
  client: client.RestClient,
  application_id: String,
  token: String,
  message_ref: String,
) -> Result(Nil, DuvetError) {
  request_void(
    client,
    "DELETE",
    message_path(application_id, token, message_ref),
    "delete interaction message",
    core.NoBody,
  )
}

// ---------------------------------------------------------------------------
// Messages in a room, as the bot
// ---------------------------------------------------------------------------

/// Sends a message to a room: its content, embeds, components and flags, as
/// `POST /api/rooms/:roomId/messages` takes them.
pub fn send_message(
  client: client.RestClient,
  room_id: String,
  message: json.Json,
) -> Result(json.Json, DuvetError) {
  request_json(
    client,
    "POST",
    "/api/rooms/" <> room_id <> "/messages",
    "send message",
    core.JsonBody(message),
    client.default_meta(client),
  )
  |> result.try(expect_json("the API answered no message"))
}

/// Edits one of the bot's messages. What it leaves out stays as it was.
pub fn edit_message_in_room(
  client: client.RestClient,
  room_id: String,
  message_id: String,
  message: json.Json,
) -> Result(json.Json, DuvetError) {
  request_json(
    client,
    "PATCH",
    "/api/rooms/" <> room_id <> "/messages/" <> message_id,
    "edit message",
    core.JsonBody(message),
    client.default_meta(client),
  )
  |> result.try(expect_json("the API answered no message"))
}

pub fn delete_message_in_room(
  client: client.RestClient,
  room_id: String,
  message_id: String,
) -> Result(Nil, DuvetError) {
  request_void(
    client,
    "DELETE",
    "/api/rooms/" <> room_id <> "/messages/" <> message_id,
    "delete message",
    core.NoBody,
  )
}

// ---------------------------------------------------------------------------
// The application's commands
// ---------------------------------------------------------------------------

/// The application's commands, as lists.
pub fn list_commands(
  client: client.RestClient,
  team_id: String,
  application_id: String,
) -> Result(List(json.Json), DuvetError) {
  request_json_list(
    client,
    "GET",
    commands_path(team_id, application_id),
    "list application commands",
    core.NoBody,
  )
}

/// Makes the application's commands exactly `commands`, all of them or none.
pub fn overwrite_commands(
  client: client.RestClient,
  team_id: String,
  application_id: String,
  commands: List(json.Json),
) -> Result(List(json.Json), DuvetError) {
  request_json_list(
    client,
    "PUT",
    commands_path(team_id, application_id),
    "overwrite application commands",
    core.JsonBody(json.array(commands, fn(command) { command })),
  )
}

/// Registers one command.
pub fn create_command(
  client: client.RestClient,
  team_id: String,
  application_id: String,
  command: json.Json,
) -> Result(json.Json, DuvetError) {
  request_json(
    client,
    "POST",
    commands_path(team_id, application_id),
    "create application command",
    core.JsonBody(command),
    client.default_meta(client),
  )
  |> result.try(expect_json("the API answered no command"))
}

/// One of the application's commands.
pub fn get_command(
  client: client.RestClient,
  team_id: String,
  application_id: String,
  command_id: String,
) -> Result(json.Json, DuvetError) {
  request_json(
    client,
    "GET",
    commands_path(team_id, application_id) <> "/" <> command_id,
    "get application command",
    core.NoBody,
    client.default_meta(client),
  )
  |> result.try(expect_json("the API answered no command"))
}

/// Edits a command; a field left out stays as it was.
pub fn update_command(
  client: client.RestClient,
  team_id: String,
  application_id: String,
  command_id: String,
  command: json.Json,
) -> Result(json.Json, DuvetError) {
  request_json(
    client,
    "PATCH",
    commands_path(team_id, application_id) <> "/" <> command_id,
    "update application command",
    core.JsonBody(command),
    client.default_meta(client),
  )
  |> result.try(expect_json("the API answered no command"))
}

pub fn delete_command(
  client: client.RestClient,
  team_id: String,
  application_id: String,
  command_id: String,
) -> Result(Nil, DuvetError) {
  request_void(
    client,
    "DELETE",
    commands_path(team_id, application_id) <> "/" <> command_id,
    "delete application command",
    core.NoBody,
  )
}

fn commands_path(team_id: String, application_id: String) -> String {
  "/api/users/@me/teams/"
  <> team_id
  <> "/applications/"
  <> application_id
  <> "/commands"
}

fn message_path(
  application_id: String,
  token: String,
  message_ref: String,
) -> String {
  "/api/webhooks/"
  <> application_id
  <> "/"
  <> token
  <> "/messages/"
  <> message_ref
}

// ---------------------------------------------------------------------------
// JSON
// ---------------------------------------------------------------------------

fn request_json(
  client: client.RestClient,
  method: String,
  path: String,
  action: String,
  body: core.Body,
  meta: core.Meta(a),
) -> Result(Option(json.Json), DuvetError) {
  client.request(client, method, path, action, body, meta)
  |> result.try(decode_optional_json)
}

fn request_json_list(
  client: client.RestClient,
  method: String,
  path: String,
  action: String,
  body: core.Body,
) -> Result(List(json.Json), DuvetError) {
  client.request(
    client,
    method,
    path,
    action,
    body,
    client.default_meta(client),
  )
  |> result.try(fn(response) {
    let text = string.trim(core.body_text(response))
    case text {
      "" -> Ok([])
      _ ->
        case json.parse(from: text, using: decode.list(decode.dynamic)) {
          Ok(values) ->
            Ok(
              list.map(values, fn(value) {
                json_value.to_json(json_value.from_dynamic(value))
              }),
            )
          Error(_) ->
            Error(error_malformed("the API's answer isn't a JSON array"))
        }
    }
  })
}

fn request_void(
  client: client.RestClient,
  method: String,
  path: String,
  action: String,
  body: core.Body,
) -> Result(Nil, DuvetError) {
  client.request(
    client,
    method,
    path,
    action,
    body,
    client.default_meta(client),
  )
  |> result.map(fn(_) { Nil })
}

fn decode_optional_json(
  response: transport.Response,
) -> Result(Option(json.Json), DuvetError) {
  case string.trim(core.body_text(response)) {
    "" -> Ok(None)
    _ ->
      case json.parse(from: core.body_text(response), using: decode.dynamic) {
        Ok(value) ->
          Ok(Some(json_value.to_json(json_value.from_dynamic(value))))
        Error(_) -> Error(error_malformed("the API's answer isn't JSON"))
      }
  }
}

fn expect_json(
  message: String,
) -> fn(Option(json.Json)) -> Result(json.Json, DuvetError) {
  fn(value) {
    case value {
      Some(inner) -> Ok(inner)
      None -> Error(error_malformed(message))
    }
  }
}

fn error_malformed(message: String) -> DuvetError {
  MalformedMessage(message)
}
