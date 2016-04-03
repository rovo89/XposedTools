# Xposed Tools

These tools can be used to compile and package the Xposed framework. They are especially useful when it comes to releasing files for various platforms and Android versions. Note that Xposed by itself is quite complicated and not suitable for beginners. You'll need a certain level of experience with C++ and general software development in order to build and modify Xposed by yourself.

----------------------------------
## General note on forks and custom builds
Xposed is open-source and contributions are very welcome. The files in this repository hopefully make it easier to compile custom versions for testing and improvements. However, please be careful when you publish your own versions. Make clear that it's an unofficial version to avoid confusion, and also remember to give proper attribution. Your version probably still includes 99% or more of the original source code that has been written since 2012, so it wouldn't be fair to  make it sound like you did all the work. Also, if you made some fixes or improvements, it's in everyone's interest that you create a pull request and contribute them back to the original project.

----------------------------------
## Build script (build.pl)
This script can perform the following steps:
- Compile the native executables (`app_process`), libraries (`libxposed_*.so`) and the modified ART runtime.
- Collect these files and put them into a common output directory.
- Create the `xposed.prop` file that serves as label for the published package.
- Create a flashable ZIP file to install the Xposed framework.

It can also compile the Java part of the framework, called `XposedBridge.jar`.

You can call `./build.pl --help` to get a list of allowed options. Usually, it's enough to specify the `-t` option, e.g `./build.pl -t arm,x86:21` to build ARM and x86 files for SDK 21 (Android 5.0).

 > You will need to have Perl installed to run this script. It also requires some Perl modules, some of which might not be pre-installed. Depending on your distribution, you can install them using your OS package manager (like apt-get, packages could be named `lib*-perl`) or via `cpan <modulename>`. Please look up the details for your installation yourself.

----------------------------------
## Build preparations
### AOSP source tree
If you have never built the native parts of Xposed before, you obviously need to download the source code. The Xposed source is placed in the complete AOSP source tree, so it's not enough to download just the SDK/NDK. Instead, please follow the [official instructions](https://source.android.com/source/building.html) to download the full source of the Android version that you want to build for. If you have done everything right, the command `make -j4 app_process` should succeed. Please note that I can't support you with these steps.

### Xposed source code
Once you have the AOSP source ready, you can integrate the Xposed sources into it. There are at least three ways to do so:
#### Local manifest
This is probably the easiest way to get started. Go to the root directory of the AOSP directory. Change into the `.repo` subdirectory and create a folder called `local_manifests`. Then create a symbolic link to one of the manifests that are included in this repository, e.g. `ln -s /path/to/this/repository/local_manifests/xposed_sdk21.xml .`. Afterwards, go back to the AOSP root directory and run `repo sync` again. This will also help to avoid some failures when compiling older Android versions on recent VMs.

#### Manual cloning
If you're afraid that `repo sync` might overwrite your changes or for some other reasons you don't want to use it, you can also clone the repositories manually. First, navigate to the `framework/base/cmds` directory and execute `git clone https://github.com/rovo89/Xposed.git xposed`. This repository contains the modified `app_process` executable and the `libxposed_*.so` files.

For variants that include ART, you will also need to replace `art` folder. However, you have to be careful that the  `repo sync` command doesn't interfere with the new directory. For this, follow the steps above to activate the `remove_art.xml` manifest and run `repo sync`. This should already remove the `art` directory in the AOSP root, but otherwise, just remove it manually. Then execute `git clone https://github.com/rovo89/android_art.git art` to download the modified files.

#### Bind mounting
In case you have many AOSP trees and want to keep the Xposed source in sync for all of them (i.e. make one change and apply it to all SDKs immediately), you can also look into bind mounts. It's basically the same as manual cloning, but you clone the files into a separate directory and then use bind mounts to map them into the AOSP tree. This is a pretty advanced technique, so I won't go into details here.

### XposedBridge source code (or prebuilt file)
If you want to compile `XposedBridge.jar` yourself, clone https://github.com/rovo89/XposedBridge and set the `javadir` variable accordingly. Make sure that the Gradle build is working fine, the Android SDK and other dependencies need to be installed for this. Then you can call `./build.pl -a java` to build and copy the JAR.

If you want to use a prebuilt file instead, copy it to a `java` subfolder in the `outdir` that you have configured in `build.conf`. For example, if `outdir` is set to `/android/out`, then the file should be stored in `/android/out/java/XposedBridge.jar`.

----------------------------------
## Configuration (build.conf)
The `build.pl` script requires some configuration. The settings are stored in INI file format in `build.conf`.  
As the configuration is specific to your local machine, it's not included in the GitHub repository. There is, however, a file called [`build.conf.sample`](build.conf.sample) with some examples. You can either copy it to `build.conf` or create your own file based on it.

##### [General]
**outdir:** The output directory for compiled files. All Xposed-specific executables/libraries are copied here, and it's used to store log files and the flashable ZIP. This directory must exist.  
**javadir:** *(Optional)* The directory that XposedBridge has been checked out to (see above).  

##### [Build]
**version:** The version number that is stored in the `/system/xposed.prop` file. It's displayed in various places, e.g. while flashing the ZIP file or in the installer. It's also the API version for Xposed, so please make sure that you use the version number that your build is based on. You're free to add any custom suffix with your own version number. You can use the placeholder `%s` to insert the current date in `YYYYMMDD` format.  
**makeflags**: Additional parameters to pass to each `make` command. The default value is `-j4`, which enables parallel build with 4 jobs.  

##### [GPG]
**sign:** *(Optional)* Might be `all` to sign all build, or `release` to sign only release builds (`-r` parameter) using `gpg -ab <file>`.  
**user:** *(Optional)* This is passed as `-u` parameter to the `gpg` command, see its man page for allowed formats.  

##### [AospDir]
The parameters in this section tell the build script where the AOSP source trees (see above) are stored for each Android version. The key is the SDK version, the value is the directory.

##### [BusyBox]
In case you want to compile the specialized BusyBox fork from https://github.com/rovo89/android_external_busybox, you have to add a mapping of platform to an Android SDK version. In the source tree for this SDK version, you have to check out the project into the folder `external/busybox`.
