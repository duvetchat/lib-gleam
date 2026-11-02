import gleam/string
import gleeunit
import gleeunit/should
import libduvet/api_router
import libduvet/gateway/events
import libduvet/gateway/feed
import libduvet/gateway/manager
import libduvet/http/client as rest
import libduvet/http/transport
import support/fixtures

pub fn main() -> Nil {
  gleeunit.main()
}

/// The same check as duvet-client's live_test.dart, against the hosted
/// service: set DUVET_LIVE=1, DUVET_EMAIL and DUVET_PASSWORD to run it. It
/// does nothing otherwise, so the suite stays offline.
pub fn live_login_and_gateway_test() {
  case fixtures.env("DUVET_LIVE") {
    "1" -> live()
    _ -> Nil
  }
}

fn live() -> Nil {
  let email = fixtures.env("DUVET_EMAIL")
  let password = fixtures.env("DUVET_PASSWORD")
  should.be_true(!string.is_empty(email))
  should.be_true(!string.is_empty(password))

  let api =
    rest.new(
      transport.hackney(20_000),
      api_router.default_router(),
      "",
      "",
      20_000,
    )
  let assert Ok(_sign_in) = rest.log_in(api, email, password)

  let events_feed = feed.start()
  let gateway =
    manager.start(
      manager.config(api)
      |> manager.with_resume(True),
    )
  let listener = feed.subscribe(events_feed)
  let assert Ok(_) = manager.connect_all(gateway, 1)
  let assert Ok(ready) = events.await_ready(listener, 15_000)
  should.be_true(!string.is_empty(ready.user.id))
  manager.destroy(gateway)
}
