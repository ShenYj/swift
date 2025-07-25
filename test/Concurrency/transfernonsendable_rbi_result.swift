// RUN: %target-swift-frontend -target %target-swift-5.1-abi-triple -swift-version 6 -disable-availability-checking -parse-as-library %s -emit-sil -o /dev/null -verify -verify-additional-prefix ni-
// RUN: %target-swift-frontend -target %target-swift-5.1-abi-triple -swift-version 6 -disable-availability-checking -parse-as-library %s -emit-sil -o /dev/null -verify -verify-additional-prefix ni-ns- -enable-upcoming-feature NonisolatedNonsendingByDefault

// REQUIRES: asserts
// REQUIRES: concurrency
// REQUIRES: swift_feature_NonisolatedNonsendingByDefault

///////////////////////
// MARK: Declaration //
///////////////////////

actor Custom {
}

@globalActor
struct CustomActor {
  static var shared: Custom {
    return Custom()
  }
}

class NonSendable {} // expected-note 3{{}}

func passNonSendable(_: NonSendable) async { }
func passTwoNonSendable(_: NonSendable, _: NonSendable) async { }

func returnsNonSendable() async -> NonSendable { NonSendable() }

@MainActor
func sendToMain<T>(_ t: T) async {}

@MainActor
func mainActorPassNonSendable(_: NonSendable) async { }

@MainActor
func mainActorReturnNonSendable() async -> NonSendable { NonSendable() }

@MainActor
func mainActorGenericPassNonSendable<T>(_: T) async { }

@MainActor
func mainActorGenericReturnNonSendable<T>() async -> T { fatalError() }

@MainActor
func mainActorAsyncFunc3() async -> ((Int) -> Int) {
  return { (_ y: Int) in y }
}

/////////////////
// MARK: Tests //
/////////////////

@MainActor func mainActorResult(_ x : Int) -> ((Int) -> Int) { 
  return { (_ y : Int) in x + y }
}

actor Calculator {
  func addCurried(_ x : Int) -> ((Int) -> Int) { 
    return { (_ y : Int) in x + y }
  }

  func add(_ x : Int, _ y : Int) -> Int {
    return x + y
  }
}

@CustomActor
func testActorCrossingBoundary() async {
  let _ = (await mainActorResult(1))(5)
  // expected-error @-1 {{non-Sendable '(Int) -> Int'-typed result can not be returned from main actor-isolated global function 'mainActorResult' to global actor 'CustomActor'-isolated context}}
  // expected-note @-2 {{a function type must be marked '@Sendable' to conform to 'Sendable'}}
  let _ = await (await mainActorResult(1))(2)
  // expected-error @-1 {{non-Sendable '(Int) -> Int'-typed result can not be returned from main actor-isolated global function 'mainActorResult' to global actor 'CustomActor'-isolated context}}
  // expected-note @-2 {{a function type must be marked '@Sendable' to conform to 'Sendable'}}
  // expected-warning @-3 {{no 'async' operations occur within 'await' expression}}

  let calc = Calculator()
  
  let _ = (await calc.addCurried(1))(2)
  // expected-error @-1 {{non-Sendable '(Int) -> Int'-typed result can not be returned from actor-isolated instance method 'addCurried' to global actor 'CustomActor'-isolated context}}
  // expected-note@-2{{a function type must be marked '@Sendable' to conform to 'Sendable'}}
  let _ = await (await calc.addCurried(1))(2) // expected-warning{{no 'async' operations occur within 'await' expression}}
  // expected-error @-1 {{non-Sendable '(Int) -> Int'-typed result can not be returned from actor-isolated instance method 'addCurried' to global actor 'CustomActor'-isolated context}}
  // expected-note @-2 {{a function type must be marked '@Sendable' to conform to 'Sendable'}}

  let plusOne = await calc.addCurried(await calc.add(0, 1))
  // expected-error @-1 {{non-Sendable '(Int) -> Int'-typed result can not be returned from actor-isolated instance method 'addCurried' to global actor 'CustomActor'-isolated context}}
  // expected-note @-2 {{a function type must be marked '@Sendable' to conform to 'Sendable'}}
  let _ = plusOne(2)
}

actor A {
  let actorNS = NonSendable()

  func actorTakesNS(_ : NonSendable) async {}

  func actorRetsNS() async -> NonSendable { NonSendable() }

  func callNonisolatedFuncsFromActor(ns: NonSendable) async {
    // Non-sendable value passed from nonisolated to actor isolated

    // We do not error in ni-ns since we just merge pass non sendable.
    await passNonSendable(ns)
    // expected-ni-error @-1 {{sending 'ns' risks causing data races}}
    // expected-ni-note @-2 {{sending 'self'-isolated 'ns' to nonisolated global function 'passNonSendable' risks causing data races between nonisolated and 'self'-isolated uses}}

    // We error here in both modes but in different places. In NI mode, we error
    // on passing ns to a nonisolated function. With ni-ns, we do not error
    // there since we inherit isolation from the caller.
    //
    // In contrast, when ni-ns is enabled, we error on sendToMain since we merge
    // ns2 into ns's region causing it to be self-isolated.
    let ns2 = NonSendable()
    await passTwoNonSendable(ns, ns2) // expected-ni-error {{sending 'ns' risks causing data races}}
    // expected-ni-note @-1 {{sending 'self'-isolated 'ns' to nonisolated global function 'passTwoNonSendable' risks causing data races between nonisolated and 'self'-isolated uses}}
    await sendToMain(ns2) // expected-ni-ns-error {{sending 'ns2' risks causing data races}}
    // expected-ni-ns-note @-1 {{sending 'self'-isolated 'ns2' to main actor-isolated global function 'sendToMain' risks causing data races between main actor-isolated and 'self'-isolated uses}}

    _ = await returnsNonSendable()
  }

  func callActorFuncsFromDiffActor(ns : NonSendable, a : A) async {
    // Non-sendable value passed between the isolation of two different actors

    await a.actorTakesNS(ns)
    // expected-error @-1 {{sending 'ns' risks causing data races}}
    // expected-note @-2 {{sending 'self'-isolated 'ns' to actor-isolated instance method 'actorTakesNS' risks causing data races between actor-isolated and 'self'-isolated uses}}

    _ = await a.actorRetsNS()
    // expected-error @-1 {{non-Sendable 'NonSendable'-typed result can not be returned from actor-isolated instance method 'actorRetsNS()' to actor-isolated context}}
  }

  func validateErrorForPassingIsolatedNonSendable(_ ns: NonSendable) async {
    await mainActorGenericPassNonSendable(ns)
    // expected-error @-1 {{sending 'ns' risks causing data races}}
    // expected-note @-2 {{sending 'self'-isolated 'ns' to main actor-isolated global function 'mainActorGenericPassNonSendable' risks causing data races between main actor-isolated and 'self'-isolated uses}}
  }

  func validateErrorReturningFromNonIsolated() async {
    let _ = await returnsNonSendable()
  }
}

func callActorFuncsFromNonisolated(a : A, ns : NonSendable) async {
  await a.actorTakesNS(ns)
  // expected-error @-1 {{sending 'ns' risks causing data races}}
  // expected-note @-2 {{sending task-isolated 'ns' to actor-isolated instance method 'actorTakesNS' risks causing data races between actor-isolated and task-isolated uses}}

  _ = await a.actorRetsNS()
  // expected-error @-1 {{non-Sendable 'NonSendable'-typed result can not be returned from actor-isolated instance method 'actorRetsNS()' to nonisolated context}}
}

func testGenericResults() async {
  let _: NonSendable = await mainActorGenericReturnNonSendable()
  // expected-error @-1 {{non-Sendable 'NonSendable'-typed result can not be returned from main actor-isolated global function 'mainActorGenericReturnNonSendable()' to nonisolated context}}
}

// https://github.com/swiftlang/swift/issues/81534
func testInlineArray() {
  let _: InlineArray<_, UInt8> = [0]
}
