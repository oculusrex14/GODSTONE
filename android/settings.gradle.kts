pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "Godstone"

include(":app")
include(":core")
include(":mesh")
include(":llm")

// T54: the nonshipping LabMesh application. A SEPARATE module, never a product
// flavour of :app -- scripts/check_tiers.py requires Gradle to declare exactly
// the shipping tiers, and the lab must not touch that invariant. It is excluded
// from every release path and from the LIGHT graph; ci/check_lab_isolation.py
// resolveth both profiles and proveth it.
include(":labmesh")
