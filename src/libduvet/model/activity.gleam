import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/option.{type Option, None, Some}
import libduvet/model/activity_type
import libduvet/model/decoding

/// When an activity started and when it ends, in Unix milliseconds.
pub type ActivityTimestamps {
  ActivityTimestamps(start: Option(Int), end: Option(Int))
}

pub fn timestamps_from_json(object: decoding.Object) -> ActivityTimestamps {
  ActivityTimestamps(
    start: decoding.optional_int(object, "start"),
    end: decoding.optional_int(object, "end"),
  )
}

/// An activity's images (a URL, or a small data URI) and their texts.
pub type ActivityAssets {
  ActivityAssets(
    large_image: Option(String),
    large_text: Option(String),
    small_image: Option(String),
    small_text: Option(String),
  )
}

pub fn assets_from_json(object: decoding.Object) -> ActivityAssets {
  ActivityAssets(
    large_image: decoding.optional_string(object, "large_image"),
    large_text: decoding.optional_string(object, "large_text"),
    small_image: decoding.optional_string(object, "small_image"),
    small_text: decoding.optional_string(object, "small_text"),
  )
}

/// What a user is doing, as an app of theirs tells the gateway
/// (ACTIVITY_UPDATE): a game, or the song Spotify plays.
pub type Activity {
  /// An [activity_type].
  Activity(
    type_: Int,
    name: String,
    details: Option(String),
    state: Option(String),
    timestamps: Option(ActivityTimestamps),
    assets: Option(ActivityAssets),
  )
}

pub fn from_json(object: decoding.Object) -> Activity {
  Activity(
    type_: decoding.int_or(object, "type", activity_type.playing),
    name: decoding.string(object, "name"),
    details: decoding.optional_string(object, "details"),
    state: decoding.optional_string(object, "state"),
    timestamps: decoding.optional_object(object, "timestamps")
      |> option_map(timestamps_from_json),
    assets: decoding.optional_object(object, "assets")
      |> option_map(assets_from_json),
  )
}

/// The activities a `user_activity_update_event` or a SPACE_CREATE member
/// carries: null reads as none.
pub fn from_list(value: Dynamic) -> List(Activity) {
  list.map(decoding.objects_value(value), from_json)
}

fn option_map(value: Option(a), with: fn(a) -> b) -> Option(b) {
  case value {
    Some(inner) -> Some(with(inner))
    None -> None
  }
}
