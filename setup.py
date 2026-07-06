"""py2app build script — makes a standalone SiberLights.app.

Build:  .venv/bin/python setup.py py2app
Output: dist/SiberLights.app
"""

from setuptools import setup

APP = ["menubar_app.py"]
OPTIONS = {
    "plist": {
        "CFBundleName": "SiberLights",
        "CFBundleDisplayName": "SiberLights",
        "CFBundleIdentifier": "com.siber.siberlights",
        "CFBundleShortVersionString": "1.0",
        "LSUIElement": True,
        "NSMicrophoneUsageDescription":
            "siberLights uses the audio input to sync the LED strip with music.",
    },
    "packages": ["rumps", "serial", "numpy", "sounddevice", "_sounddevice_data", "cffi"],
}

setup(
    name="SiberLights",
    app=APP,
    options={"py2app": OPTIONS},
    setup_requires=["py2app"],
)
