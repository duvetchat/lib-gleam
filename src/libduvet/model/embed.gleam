import gleam/json
import gleam/option.{type Option, None, Some}
import libduvet/model/decoding
import libduvet/model/encoding

pub type EmbedMedia {
  EmbedMedia(
    url: String,
    width: Option(Int),
    height: Option(Int),
    /// A video's media type, when known: video/* plays as a file, text/html is
    /// a player page.
    content_type: Option(String),
  )
}

pub fn embed_media_from_json(object: decoding.Object) -> EmbedMedia {
  EmbedMedia(
    url: decoding.string(object, "url"),
    width: decoding.optional_int(object, "width"),
    height: decoding.optional_int(object, "height"),
    content_type: decoding.optional_string(object, "content_type"),
  )
}

pub fn embed_media_to_json(media: EmbedMedia) -> json.Json {
  json.object(
    encoding.present([
      Some(#("url", json.string(media.url))),
      encoding.optional_int("width", media.width),
      encoding.optional_int("height", media.height),
      encoding.optional_string("content_type", media.content_type),
    ]),
  )
}

pub type EmbedFooter {
  EmbedFooter(text: String, icon_url: Option(String))
}

pub fn embed_footer_from_json(object: decoding.Object) -> EmbedFooter {
  EmbedFooter(
    text: decoding.string(object, "text"),
    icon_url: decoding.optional_string(object, "icon_url"),
  )
}

pub fn embed_footer_to_json(footer: EmbedFooter) -> json.Json {
  json.object(
    encoding.present([
      Some(#("text", json.string(footer.text))),
      encoding.optional_string("icon_url", footer.icon_url),
    ]),
  )
}

pub type EmbedAuthor {
  EmbedAuthor(name: String, url: Option(String), icon_url: Option(String))
}

pub fn embed_author_from_json(object: decoding.Object) -> EmbedAuthor {
  EmbedAuthor(
    name: decoding.string(object, "name"),
    url: decoding.optional_string(object, "url"),
    icon_url: decoding.optional_string(object, "icon_url"),
  )
}

pub fn embed_author_to_json(author: EmbedAuthor) -> json.Json {
  json.object(
    encoding.present([
      Some(#("name", json.string(author.name))),
      encoding.optional_string("url", author.url),
      encoding.optional_string("icon_url", author.icon_url),
    ]),
  )
}

pub type EmbedField {
  EmbedField(name: String, value: String, inline: Bool)
}

pub fn embed_field_from_json(object: decoding.Object) -> EmbedField {
  EmbedField(
    name: decoding.string(object, "name"),
    value: decoding.string(object, "value"),
    inline: decoding.bool_or(object, "inline", False),
  )
}

pub fn embed_field_to_json(field: EmbedField) -> json.Json {
  json.object([
    #("name", json.string(field.name)),
    #("value", json.string(field.value)),
    #("inline", json.bool(field.inline)),
  ])
}

pub type EmbedColor {
  EmbedColor(
    color_from: Option(Int),
    color_via: Option(Int),
    color_to: Option(Int),
  )
}

pub fn embed_color_from_json(object: decoding.Object) -> EmbedColor {
  EmbedColor(
    color_from: decoding.optional_int(object, "color_from"),
    color_via: decoding.optional_int(object, "color_via"),
    color_to: decoding.optional_int(object, "color_to"),
  )
}

pub fn embed_color_to_json(color: EmbedColor) -> json.Json {
  json.object(
    encoding.present([
      encoding.optional_int("color_from", color.color_from),
      encoding.optional_int("color_via", color.color_via),
      encoding.optional_int("color_to", color.color_to),
    ]),
  )
}

pub type Embed {
  Embed(
    type_: Option(String),
    provider: Option(String),
    title: Option(String),
    description: Option(String),
    url: Option(String),
    timestamp: Option(String),
    color: Option(EmbedColor),
    footer: Option(EmbedFooter),
    image: Option(EmbedMedia),
    thumbnail: Option(EmbedMedia),
    video: Option(EmbedMedia),
    author: Option(EmbedAuthor),
    fields: Option(List(EmbedField)),
  )
}

pub fn from_json(object: decoding.Object) -> Embed {
  Embed(
    type_: decoding.optional_string(object, "type"),
    provider: decoding.optional_string(object, "provider"),
    title: decoding.optional_string(object, "title"),
    description: decoding.optional_string(object, "description"),
    url: decoding.optional_string(object, "url"),
    timestamp: decoding.optional_string(object, "timestamp"),
    color: decoding.optional_object(object, "color")
      |> option_map(embed_color_from_json),
    footer: decoding.optional_object(object, "footer")
      |> option_map(embed_footer_from_json),
    image: decoding.optional_object(object, "image")
      |> option_map(embed_media_from_json),
    thumbnail: decoding.optional_object(object, "thumbnail")
      |> option_map(embed_media_from_json),
    video: decoding.optional_object(object, "video")
      |> option_map(embed_media_from_json),
    author: decoding.optional_object(object, "author")
      |> option_map(embed_author_from_json),
    fields: decoding.optional_objects(object, "fields", embed_field_from_json),
  )
}

pub fn to_json(embed: Embed) -> json.Json {
  json.object(
    encoding.present([
      encoding.optional_string("type", embed.type_),
      encoding.optional_string("provider", embed.provider),
      encoding.optional_string("title", embed.title),
      encoding.optional_string("description", embed.description),
      encoding.optional_string("url", embed.url),
      encoding.optional_string("timestamp", embed.timestamp),
      encoding.optional_json("color", embed.color, embed_color_to_json),
      encoding.optional_json("footer", embed.footer, embed_footer_to_json),
      encoding.optional_json("image", embed.image, embed_media_to_json),
      encoding.optional_json("thumbnail", embed.thumbnail, embed_media_to_json),
      encoding.optional_json("video", embed.video, embed_media_to_json),
      encoding.optional_json("author", embed.author, embed_author_to_json),
      encoding.optional_list_json("fields", embed.fields, embed_field_to_json),
    ]),
  )
}

fn option_map(value: Option(a), with: fn(a) -> b) -> Option(b) {
  case value {
    Some(inner) -> Some(with(inner))
    None -> None
  }
}
