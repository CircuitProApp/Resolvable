import ResolvableMacro
import Foundation



@Resolvable
struct SampleModel {
    var name: String
    
    @Overridable var value: Double
}
    
    


// The purpose of this client is to ensure that the project compiles.
// When you build the 'ResolvableMacroClient' scheme, the compiler will
// attempt to expand the `@Resolvable` macro. If there are any errors in the
// macro's basic setup, the build will fail.

print("ResolvableMacroClient has finished running. If this message appears, the macro skeleton is set up correctly.")
