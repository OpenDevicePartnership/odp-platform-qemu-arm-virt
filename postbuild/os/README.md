# Booting Validation OS Image

## Preparing the Windows Validation OS (WinVOS) Image

WinVOS is a pared down Windows OS image that is convenient for basic development while also booting relatively quickly under QEMU.  

The image is built by the `build_os_image` GitHub Actions workflow (`.github/workflows/build-os.yml`), which injects the QEMU drivers listed in `prebuilt/driverlist.txt`. On pushes to `main` it publishes `os-image.zip` as an asset on the rolling `latest` prerelease; pull requests build the image for validation only and publish nothing. Running `make run_os` or `make qcow2` downloads and unzips that asset into `prebuilt/ValidationOS.vhdx`. The download is anonymous, so no `gh auth login` is needed. To build manually, download the ISO from https://aka.ms/DownloadValidationOS_arm64.


## Booting QEMU `virt` to Windows

After you have created a ValidationOS.vhdx with your required files, simply copy it to the prebuilt folder and from the root folder run
    `make run_os`

This will generate the qcow2 image from the vhdx and run your BIOS in the parent folder path and boot to a command prompt. Your output display will be redirected to VNC port 5900 by default. You can use and VNC Viewer to open the display `127.0.0.1:5900`. 

If you want you can force regeneration of the winvos.qcow2 image using
    `make qcow2`

## Connecting with Windbg

GDB server is at:  `127.0.0.1:5555`. 

Windbg can be connected on  `windbg -k com:ipport=56789,port=127.0.0.1 -v`
