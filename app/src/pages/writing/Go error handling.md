---
layout: ../../layouts/MarkdownPostLayout.astro
title: 'Go error handling'
pubDate: 2026-04-06
description: 'Go error handling'
author: 'tyzerrr'
---

## Time to go next stage
I've let it pass error handling in Go for a long time.  
But, it was not critical for me.  
Basically, I write my code by hand, but in almost cases, I let ClaudeCode review my code, so I had no problem.  
Also, I know a few tips, like wrapping `fmt.Errorf`, wrap and add some context in each layer like `NewInfrastructureError()`.  

I need to push me off to next step to get confidence for my code.
It's time to go next stage, mastering error handling.

## `errors.Is()` and `errors.As()`, `Unwrap()`
In short, `errors.Is()` is for **equivalence evaluation**, `errors.As()` is for **type assertion**.  
`errors.Is(err error, another error) bool` returns boolean value means that `another` has same value for `err`.  
`errors.As(err error, another any) bool` returns boolean value means that `another` can assignable for `err`. (`another` needs to be **pointer**.)  

`errors.Is()` and `erros.As()` implementation is here.

```go
package errors

func Is(err, target error) bool {
	if err == nil || target == nil {
		return err == target
	}

	isComparable := reflectlite.TypeOf(target).Comparable()
	return is(err, target, isComparable)
}

func is(err, target error, targetComparable bool) bool {
	for {
		if targetComparable && err == target {
			return true
		}
		if x, ok := err.(interface{ Is(error) bool }); ok && x.Is(target) {
			return true
		}
		switch x := err.(type) {
		case interface{ Unwrap() error }:
			err = x.Unwrap()
			if err == nil {
				return false
			}
		case interface{ Unwrap() []error }:
			for _, err := range x.Unwrap() {
				if is(err, target, targetComparable) {
					return true
				}
			}
			return false
		default:
			return false
		}
	}
}
```

```go
func As(err error, target any) bool {
	if err == nil {
		return false
	}
	if target == nil {
		panic("errors: target cannot be nil")
	}
	val := reflectlite.ValueOf(target)
	typ := val.Type()
	if typ.Kind() != reflectlite.Ptr || val.IsNil() {
		panic("errors: target must be a non-nil pointer")
	}
	targetType := typ.Elem()
	if targetType.Kind() != reflectlite.Interface && !targetType.Implements(errorType) {
		panic("errors: *target must be interface or implement error")
	}
	return as(err, target, val, targetType)
}

func as(err error, target any, targetVal reflectlite.Value, targetType reflectlite.Type) bool {
	for {
		if reflectlite.TypeOf(err).AssignableTo(targetType) {
			targetVal.Elem().Set(reflectlite.ValueOf(err))
			return true
		}
		if x, ok := err.(interface{ As(any) bool }); ok && x.As(target) {
			return true
		}
		switch x := err.(type) {
		case interface{ Unwrap() error }:
			err = x.Unwrap()
			if err == nil {
				return false
			}
		case interface{ Unwrap() []error }:
			for _, err := range x.Unwrap() {
				if err == nil {
					continue
				}
				if as(err, target, targetVal, targetType) {
					return true
				}
			}
			return false
		default:
			return false
		}
	}
}
```

As you can see, both calls `Unwrap()` internally.
We can easily find out from method signature, but we see it.

```go
// Unwrap returns the result of calling the Unwrap method on err, if err's
// type contains an Unwrap method returning error.
// Otherwise, Unwrap returns nil.
//
// Unwrap only calls a method of the form "Unwrap() error".
// In particular Unwrap does not unwrap errors returned by [Join].
func Unwrap(err error) error {
	u, ok := err.(interface {
		Unwrap() error
	})
	if !ok {
		return nil
	}
	return u.Unwrap()
}
```
That is pretty simple, just calls `Unwrap()` and return the result.
`errors.As()` calls `Unwrap()` recursively, then if value is assignable for another, returns true.
As same, `errors.Is()` calls `Unwrap()` recursively, then if value is same for another, return true.

So, if we use custom error, we need to implement `MyError.Unwrap()` to work fine both important errors package method.

```go
package main

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
)

type MyError struct {
	msg string
	err error
}

func NewMyError(msg string, err error) *MyError {
	return &MyError{
		msg: msg,
		err: err,
	}
}

func (e *MyError) Error() string {
	return e.msg
}

func (e *MyError) Unwrap() error {
	return e.err
}

func main() {
	if _, err := os.Open("non-existing"); err != nil {
		me := &MyError{msg: "this is wrapped error", err: err}
		var pathError *fs.PathError
		if errors.As(me, &pathError) {
			fmt.Printf("error is as pathError, %v\n", pathError.Path)
		}
		if errors.Is(me, pathError) {
			fmt.Println("myerror is err")
		}
	}
}
```

## Why do we need to wrap with `fmt.Errorf("%w", err)?`
The mechanism behind `fmt.Errorf()` and its ability to wrap errors is straightforward.  
When the function detects the `%w` verb, it returns a specific internal type that implements the `Unwrap()` error method.

When you use `fmt.Errorf("...: %w", err)`, the `fmt` package creates an instance of an internal struct (specifically `*fmt.wrapError`).  
Its structure and implementation look roughly like this:  

```go
// Simplified internal representation within the fmt package
type wrapError struct {
    msg string
    err error // Holds the error passed via %w
}

func (e *wrapError) Error() string { return e.msg }
func (e *wrapError) Unwrap() error { return e.err } // This is the key!
```

Since this returned error implements the `Unwrap()`, both `errors.Is()` and `errors.As()` can traverse the error chain to find the underlying cause.  
Essentially, `fmt.Errorf()` is doing exactly what you would do when manually implementing a custom error type with an `Unwrap()`.
