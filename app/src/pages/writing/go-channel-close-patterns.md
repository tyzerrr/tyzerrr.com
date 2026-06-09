---
layout: ../../layouts/MarkdownPostLayout.astro
title: 'Closing channels in Go: what I had wrong'
pubDate: 2026-06-09
description: 'send vs close vs receive, and why closing a channel inside a goroutine is not an anti-pattern'
author: 'tyzerrr'
---

## The code that made me doubt myself

I was reading a graceful-shutdown helper for a gRPC server and stopped on this:

```go
func (c *Container) GracefulStop(ctx context.Context) {
    done := make(chan struct{})
    go func() {
        c.grpcServer.GracefulStop()
        close(done)
    }()
    select {
    case <-done:
    case <-ctx.Done():
        c.grpcServer.Stop()
        <-done
    }
}
```

The intent is: drain in-flight RPCs gracefully, but if `ctx` (a 25s budget) expires first, hard-stop the server so the process can move on before Kubernetes sends `SIGKILL`.

My gut said *"this is wrong"*. The reason I gave myself: **"closing a channel inside a goroutine is an anti-pattern — doesn't that deadlock?"**

It turns out my gut was wrong, and the reason it was wrong is worth writing down, because it came from mixing up two different things.

## What I actually misunderstood

I had collapsed three different channel operations into one fuzzy idea of "channels are dangerous". They are not equally dangerous. Here is the table I wish I'd had:

| Operation | Does it block? | Can it panic? |
|---|---|---|
| `ch <- v` (send) | **Yes** — blocks until a receiver is ready (unbuffered) | Yes — panics if `ch` is already closed |
| `close(ch)` | **No** — never blocks | Yes — panics on double `close`, or on closing a `nil` channel |
| `<-ch` (receive) | Blocks until a value arrives **or the channel is closed** | No |
| `<-ch` on a *closed* channel | **No** — returns the zero value immediately | No |

The deadlock story I half-remembered is about **send**, not **close**. This is the classic leak:

```go
done := make(chan struct{})
go func() {
    heavyWork()
    done <- struct{}{} // SEND: blocks until someone receives
}()
// if main returns here without <-done, the goroutine is stuck forever
```

`done <- struct{}{}` parks the goroutine until a receiver shows up. If nobody ever receives, that goroutine leaks (and if it were the last runnable goroutine, the runtime reports `all goroutines are asleep - deadlock!`).

But `close(done)` is a completely different operation. **`close` never blocks.** And receiving from a closed channel **never blocks** either — it returns immediately. So the original code has no way to deadlock on `done`.

My mistake in one sentence: **I confused `ch <- v` (which blocks) with `close(ch)` (which doesn't).**

## The rule that actually matters: who owns the channel

The real Go guideline is *not* "don't close inside a goroutine". It is:

> **The goroutine that sends on a channel is the one that closes it. Receivers never close, and a channel is only ever closed once.**

The reasons:

- Closing from the **receiver** side is unsafe, because a sender might still try to send → `panic: send on closed channel`.
- Closing the **same channel twice** → `panic: close of closed channel`.

So the question to ask is never "is this inside a goroutine?". It's "**is there exactly one owner that closes, and does everyone else only receive?**"

Apply that to the original code:

| Goroutine | What it does to `done` |
|---|---|
| the `go func()` running `GracefulStop` | `close(done)` — once, and only this goroutine ever touches the write side |
| the caller (`select` / `<-done`) | only **receives** |

One owner closes, everyone else receives. That is the textbook-correct pattern, not an anti-pattern. Running it inside a goroutine is irrelevant to safety.

## Why `Stop()` in the timeout branch doesn't strand the goroutine

One more thing that confused me: in the `ctx.Done()` branch we call `c.grpcServer.Stop()` and then `<-done`. If `GracefulStop()` were still blocking inside the goroutine, wouldn't `<-done` wait forever?

No — because `Stop()` forcibly closes the open connections, which makes the in-progress `GracefulStop()` return. The same single goroutine then reaches `close(done)`, and `<-done` unblocks. Combined with the "close never blocks" fact, the goroutine is guaranteed to finish in both branches. **No leak, no deadlock.**

## Correct patterns

### Pattern 1: signal completion with `close` (no value needed)

When you only need to broadcast "I'm done", close an empty-struct channel. `close` is perfect here because it never blocks and every receiver is released at once.

```go
func waitWithTimeout(ctx context.Context, work func()) {
    done := make(chan struct{})
    go func() {
        work()
        close(done) // owner closes, once
    }()
    select {
    case <-done:
        // finished in time
    case <-ctx.Done():
        // timed out; goroutine still finishes and closes done on its own
    }
}
```

This is exactly the shape of the gRPC graceful-stop code.

### Pattern 2: stream values, owner closes when finished

```go
func produce() <-chan int {
    out := make(chan int)
    go func() {
        defer close(out) // the sole sender closes, exactly once
        for i := 0; i < 5; i++ {
            out <- i
        }
    }()
    return out
}

func main() {
    for v := range produce() { // range stops cleanly when out is closed
        fmt.Println(v)
    }
}
```

Returning the channel as `<-chan int` (receive-only) makes the ownership explicit at the type level: callers literally cannot send or close it.

### Pattern 3: fan-in, close once after all senders finish

When multiple goroutines send, none of them may close. Let a `WaitGroup` decide when everyone is done, then a single closer closes.

```go
func merge(chans ...<-chan int) <-chan int {
    out := make(chan int)
    var wg sync.WaitGroup
    for _, c := range chans {
        wg.Add(1)
        go func(c <-chan int) {
            defer wg.Done()
            for v := range c {
                out <- v
            }
        }(c)
    }
    go func() {
        wg.Wait()
        close(out) // exactly one closer, after every sender has stopped
    }()
    return out
}
```

## Anti-patterns

### Anti-pattern 1: the receiver closes

```go
func bad(out chan int) {
    for v := range out {
        if v == 0 {
            close(out) // BUG: receiver closing while a sender may still send
        }
    }
}
// elsewhere: out <- x  → panic: send on closed channel
```

The fix is ownership: only the sending side closes.

### Anti-pattern 2: closing twice

```go
done := make(chan struct{})
close(done)
close(done) // panic: close of closed channel
```

If two goroutines might both want to close, guard it with `sync.Once`:

```go
var once sync.Once
closeDone := func() { once.Do(func() { close(done) }) }
```

### Anti-pattern 3: leaking via send with no receiver (the thing I confused `close` with)

```go
func leak() {
    done := make(chan struct{})
    go func() {
        heavyWork()
        done <- struct{}{} // blocks forever if the caller stopped listening
    }()
    // early return → goroutine parked on the send forever
}
```

Two fixes: signal with `close(done)` instead of a send (close never blocks), or make the channel buffered (`make(chan struct{}, 1)`) so the send can complete without a waiting receiver.

### Anti-pattern 4: sending on a `nil` channel (blocks forever)

```go
var ch chan int   // nil
ch <- 1           // blocks forever
// <-ch also blocks forever; close(ch) panics
```

A `nil` channel is occasionally useful on purpose (disabling a `select` case), but an accidentally-`nil` channel is a silent hang.

## What I needed to understand, in summary

1. **`send`, `close`, and `receive` are three different operations with different blocking and panic rules.** Don't lump them together. `send` blocks; `close` never blocks; receiving from a closed channel never blocks.
2. **The real rule is ownership, not location.** "Don't close inside a goroutine" is not a rule. "The sole sender closes, exactly once, and receivers never close" is the rule. Closing inside a goroutine is fine — and common — when that goroutine is the owner.
3. **The deadlock I was scared of comes from `send` with no receiver**, not from `close`. Signaling completion with `close(done)` is the *fix* for that leak, not a cause of it.
4. **`select { case <-done: case <-ctx.Done(): }` is the canonical "wait for work, but give up after a deadline" idiom.** It's safe to learn as a unit and reuse.

The gRPC `GracefulStop` helper I started from was correct all along. What was broken was my mental model, and it broke in a specific, fixable place: I thought `close` behaved like `send`.
