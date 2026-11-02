import gleam/bit_array
import gleam/erlang/process.{type Pid, type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/uri
import libduvet/http/transport

/// How long a request may go without progress before it fails: connecting,
/// each piece of its body sent and each piece of the answer received count as
/// progress, so an upload that keeps moving isn't cut short.
pub const default_request_timeout = 20_000

/// Why a request didn't finish. The names and payloads carry what Dart's
/// TimeoutException, RequestAbortedException and the transport's own errors
/// carried, so logs and messages keep their shape.
pub type SendError {
  /// Nothing moved for [timeout_ms] while sending [method] [path].
  TimedOut(method: String, path: String, timeout_ms: Int)
  /// The caller's abort trigger completed first.
  Aborted
  /// The connection failed or closed.
  Network(String)
}

/// What a request's progress callback hears: the bytes of the body sent so
/// far, and their total.
pub type Progress =
  fn(Int, Int) -> Nil

type SupervisorMessage {
  Progressed(sent: Int)
  Activity
  Finished(Result(transport.Response, transport.ExchangeError))
  Ticked
  AbortedByCaller
}

/// Sends [request] and reads the whole answer, in a process of its own so that
/// the connection can be dropped mid-flight.
///
/// It fails with [TimedOut] when [timeout_ms] passes without progress, and
/// with [Aborted] when [abort] receives first; either way the exchange's
/// process is killed, which closes its connection. [on_progress] hears the
/// bytes sent so far and their total.
pub fn send_within(
  transport transport: transport.Transport,
  request request: transport.Request,
  timeout timeout_ms: Int,
  abort abort: Option(Subject(a)),
  on_progress on_progress: Option(Progress),
) -> Result(transport.Response, SendError) {
  let total =
    list.fold(request.body, 0, fn(sum, piece) {
      sum + bit_array.byte_size(piece)
    })

  let progress_subject = process.new_subject()
  let activity_subject = process.new_subject()
  let result_subject = process.new_subject()
  let tick_subject = process.new_subject()

  let child =
    process.spawn_unlinked(fn() {
      let outcome =
        transport(
          request,
          fn(sent) { process.send(progress_subject, sent) },
          fn() { process.send(activity_subject, Nil) },
        )
      process.send(result_subject, outcome)
    })

  let selector =
    process.new_selector()
    |> process.select_map(progress_subject, Progressed)
    |> process.select_map(activity_subject, fn(_) { Activity })
    |> process.select_map(result_subject, Finished)
    |> process.select_map(tick_subject, fn(_) { Ticked })

  let selector = case abort {
    Some(subject) ->
      process.select_map(selector, subject, fn(_) { AbortedByCaller })
    None -> selector
  }

  let timer = process.send_after(tick_subject, timeout_ms, Nil)
  supervise(
    child,
    selector,
    tick_subject,
    timer,
    request,
    timeout_ms,
    total,
    on_progress,
  )
}

fn supervise(
  child: Pid,
  selector: process.Selector(SupervisorMessage),
  tick_subject: Subject(Nil),
  timer: process.Timer,
  request: transport.Request,
  timeout_ms: Int,
  total: Int,
  on_progress: Option(Progress),
) -> Result(transport.Response, SendError) {
  case process.selector_receive_forever(selector) {
    Progressed(sent) -> {
      process.cancel_timer(timer)
      case on_progress {
        Some(callback) -> callback(sent, total)
        None -> Nil
      }
      let timer = process.send_after(tick_subject, timeout_ms, Nil)
      supervise(
        child,
        selector,
        tick_subject,
        timer,
        request,
        timeout_ms,
        total,
        on_progress,
      )
    }
    Activity -> {
      process.cancel_timer(timer)
      let timer = process.send_after(tick_subject, timeout_ms, Nil)
      supervise(
        child,
        selector,
        tick_subject,
        timer,
        request,
        timeout_ms,
        total,
        on_progress,
      )
    }
    Finished(Ok(response)) -> {
      process.cancel_timer(timer)
      Ok(response)
    }
    Finished(Error(transport.Timeout)) -> {
      process.cancel_timer(timer)
      process.kill(child)
      Error(TimedOut(
        method: request.method,
        path: path_of(request.url),
        timeout_ms: timeout_ms,
      ))
    }
    Finished(Error(transport.Network(reason))) -> {
      process.cancel_timer(timer)
      Error(Network(reason))
    }
    Ticked -> {
      process.kill(child)
      Error(TimedOut(
        method: request.method,
        path: path_of(request.url),
        timeout_ms: timeout_ms,
      ))
    }
    AbortedByCaller -> {
      process.cancel_timer(timer)
      process.kill(child)
      Error(Aborted)
    }
  }
}

fn path_of(url: String) -> String {
  case uri.parse(url) {
    Ok(parsed) -> parsed.path
    Error(_) -> url
  }
}
