import ResolvableMacro
import Foundation

// By wrapping our model inside an enum, it is no longer at the "global scope".
// The macro can now safely generate its peer types (like SampleModelDefinition)
// inside the TestModels namespace.
enum TestModels {
    
    struct SampleModel {
        var name: String
        
        @Overridable var value: Double
    }
    
    /// Auto-generated `Definition` for SampleModel.
    public struct SampleModelDefinition: Identifiable, Codable, Hashable {
        public var id: UUID = UUID()
        
        
        var name: String
        
        var value: Double
    }
    
    /// Auto-generated ad-hoc `Instance` for SampleModel.
    public struct SampleModelInstance: Identifiable, Codable, Hashable {
        public var id: UUID = UUID()
        
        
        var name: String
        
        var value: Double
    }
    
    /// Auto-generated `Override` for SampleModel.
    public struct SampleModelOverride: Identifiable, Codable, Hashable {
        public let definitionID: UUID
        public var id: UUID {
            definitionID
        }
        
        var value: Double? = nil
    }
    
    /// Auto-generated `Source` enum for SampleModel.
    public enum SampleModelSource: Hashable {
        case definition(definitionID: UUID)
        case instance(instanceID: UUID)
    }
    
    /// Auto-generated `Resolved` view model for SampleModel.
    public struct SampleModelResolved: Identifiable, Hashable {
        public var id: UUID {
            switch source {
            case .definition(let definitionID):
                return definitionID
            case .instance(let instanceID):
                return instanceID
            }
        }
        
        public let source: SampleModelSource
        var name: String
        
        var value: Double
    }
    
    /// Auto-generated `Resolver` for SampleModel.
    public struct SampleModelResolver {
        public static func resolve(
            definitions: [SampleModelDefinition],
            overrides: [SampleModelOverride],
            instances: [SampleModelInstance]
        ) -> [SampleModelResolved] {
            
            let overrideDict = Dictionary(uniqueKeysWithValues: overrides.map {
                ($0.definitionID, $0)
            })
            
            let resolvedFromDefinitions = definitions.map { definition -> SampleModelResolved in
                let override = overrideDict[definition.id]
                return SampleModelResolved(
                    source: .definition(definitionID: definition.id),
                    name: definition.name,
                    value: override?.value ?? definition.value
                )
            }
            
            let resolvedFromInstances = instances.map { instance -> SampleModelResolved in
                return SampleModelResolved(
                    source: .instance(instanceID: instance.id),
                    name: instance.name,
                    value: instance.value
                )
            }
            
            return resolvedFromDefinitions + resolvedFromInstances
        }
    }
    
    
    extension TestModels.SampleModel {
        public typealias Definition = TestModels.SampleModelDefinition
        public typealias Instance   = TestModels.SampleModelInstance
        public typealias Override   = TestModels.SampleModelOverride
        public typealias Resolved   = TestModels.SampleModelResolved
        public typealias Source     = TestModels.SampleModelSource
        public typealias Resolver   = TestModels.SampleModelResolver
    }
    
}

// The purpose of this client is to ensure that the project compiles.
// When you build the 'ResolvableMacroClient' scheme, the compiler will
// attempt to expand the `@Resolvable` macro. If there are any errors in the
// macro's basic setup, the build will fail.

print("ResolvableMacroClient has finished running. If this message appears, the macro skeleton is set up correctly.")
