import Foundation
import SandboxCore

var assertionFailures: [String] = []
func fail(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
    let detail = "\(file):\(line): \(message)"
    assertionFailures.append(detail)
    print("  FAIL \(detail)")
}
func expectEqual<T: Equatable>(_ lhs: @autoclosure () throws -> T, _ rhs: @autoclosure () throws -> T,
                               file: StaticString = #filePath, line: UInt = #line) {
    do { let a = try lhs(), b = try rhs(); if a != b { fail("expected \(a) == \(b)", file: file, line: line) } }
    catch { fail("unexpected error: \(error)", file: file, line: line) }
}
func expectNotEqual<T: Equatable>(_ lhs: @autoclosure () throws -> T, _ rhs: @autoclosure () throws -> T,
                                  file: StaticString = #filePath, line: UInt = #line) {
    do { if try lhs() == rhs() { fail("expected unequal values", file: file, line: line) } }
    catch { fail("unexpected error: \(error)", file: file, line: line) }
}
func expectTrue(_ value: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    expectEqual(try value(), true, file: file, line: line)
}
func expectFalse(_ value: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    expectEqual(try value(), false, file: file, line: line)
}
func expectNil<T>(_ value: @autoclosure () throws -> T?, file: StaticString = #filePath, line: UInt = #line) {
    do { if try value() != nil { fail("expected nil", file: file, line: line) } }
    catch { fail("unexpected error: \(error)", file: file, line: line) }
}
func expectThrows<T>(_ value: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    do { _ = try value(); fail("expected an error", file: file, line: line) } catch {}
}
func expectNoThrow<T>(_ value: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    do { _ = try value() } catch { fail("unexpected error: \(error)", file: file, line: line) }
}
func expectLess<T: Comparable>(_ lhs: T, _ rhs: T, file: StaticString = #filePath, line: UInt = #line) {
    if !(lhs < rhs) { fail("expected \(lhs) < \(rhs)", file: file, line: line) }
}
func expectLessOrEqual<T: Comparable>(_ lhs: T, _ rhs: T, file: StaticString = #filePath, line: UInt = #line) {
    if !(lhs <= rhs) { fail("expected \(lhs) <= \(rhs)", file: file, line: line) }
}
func expectGreater<T: Comparable>(_ lhs: T, _ rhs: T, file: StaticString = #filePath, line: UInt = #line) {
    if !(lhs > rhs) { fail("expected \(lhs) > \(rhs)", file: file, line: line) }
}
func unwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw SandboxError("expected non-nil value") }; return value
}
