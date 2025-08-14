import Resolvable
import Foundation

@Resolvable
struct SampleModel {
    var name: String
    
    @Overridable var value: Double
}

print("ResolvableMacroClient has finished running. If this message appears, the macro skeleton is set up correctly.")
