@file:Suppress("DEPRECATION")

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}

subprojects {
    val configureSdk = {
        val android = project.extensions.findByName("android")
        if (android is com.android.build.gradle.BaseExtension) {
            android.compileSdkVersion(36)
        }
    }
    if (project.state.executed) {
        configureSdk()
    } else {
        project.afterEvaluate {
            configureSdk()
        }
    }

    // 动态检测各个子模块自带的 Java 版本，使 Kotlin 编译与 Java 保持 100% 物理强对齐，解决非对称编译冲突
    tasks.withType(org.jetbrains.kotlin.gradle.tasks.KotlinCompile::class.java).configureEach {
        val javaVersion = project.extensions.findByName("android")?.let { android ->
            if (android is com.android.build.gradle.BaseExtension) {
                android.compileOptions.sourceCompatibility.toString()
            } else null
        } ?: "11"

        val targetJvm = when (javaVersion) {
            "1.8" -> org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_1_8
            "11" -> org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_11
            "17" -> org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
            "21" -> org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_21
            else -> org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_11
        }

        compilerOptions {
            jvmTarget.set(targetJvm)
        }
    }
}

