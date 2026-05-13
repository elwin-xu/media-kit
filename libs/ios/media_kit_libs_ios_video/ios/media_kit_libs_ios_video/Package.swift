// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let libmpvTargets = [
    "Ass",
    "Avcodec",
    "Avfilter",
    "Avformat",
    "Avutil",
    "Dav1d",
    "Freetype",
    "Fribidi",
    "Harfbuzz",
    "Mbedcrypto",
    "Mbedtls",
    "Mbedx509",
    "Mpv",
    "Png16",
    "Swresample",
    "Swscale",
    "Uchardet",
    "Xml2"
]

let libmpvArtifactBase = "https://github.com/media-kit/libmpv-darwin-build/releases/download/v0.7.0/libmpv-xcframeworks_v0.7.0_ios-universal-video-full"
let libmpvChecksums = [
    "Ass": "99d8430307c4cbc4bb50f73f99b6b429954dd09a182a108437f1d8074e9f635b",
    "Avcodec": "cb40e113e83994295e24edae9746121127b4910a2e81b0d3adbc515eb08e1d0b",
    "Avfilter": "6fa56a3aee26fbf167b1538c541bd2a448a071d3c9ef635ec4152e952a09bf42",
    "Avformat": "fa7584f872a8d5c8a3eee0b1766b2e6f486c0be984a6bc259e03afdf226f1217",
    "Avutil": "20a57936ec484cfc396f61448529e62885695bb1fd11640199de22c1b325c652",
    "Dav1d": "aa26871919b34bf07ccb219bd38aae43482ec4454cb20d99c6f649fd3b883511",
    "Freetype": "e6135c653d38008dcfcf685c5e19a7dcd33fc2d41a2e52f92316b44957e7d314",
    "Fribidi": "4118aa331ba791300ac253d71fbce9f90c8b630a2bd578431e4fee79b534c0e9",
    "Harfbuzz": "7807007c416cabe4caa63c3524a2637b47babbe52d1d044e2d37f410b974ec0d",
    "Mbedcrypto": "332fb11207dd0a05dd02775db3cc608a9ebe9b548a8cff4a504100f266acbce4",
    "Mbedtls": "e4fcdaaf43e46325b9be132e5d279c7ac3298b3973b97000f823c1d10468b9f8",
    "Mbedx509": "bb17ca6a8092345daa69c25018ad0f2fcce009a747691a0f2ec51deafba62d73",
    "Mpv": "77d903b2d09c3fa6aa0f02fdaeec9b51154b9bc2956df8c04c89691ffec60100",
    "Png16": "9ed6012c959d9ef2cdea2750338629982cbf779ec70bb3f8e22011ee883ec0da",
    "Swresample": "2efde6fe1d2fca3db13c9cd2174cc662fb032bb7feb359431889ce0f4dd33b80",
    "Swscale": "60eed342d33ec8807f0c800986eda57dc1cc96f239d9c0b703bce18a30fdafd5",
    "Uchardet": "2dd5b08cf141acc12b67b4064361ce6544248e2f9da5260b8e61157d0b0b6bdd",
    "Xml2": "7b274b67cb2d553ff826c5f1aec5222359f7179952a28d2d1ff37790feb5797f"
]
let libmpvProductTargets: [String] = ["media_kit_libs_ios_video"] + libmpvTargets

let package = Package(
    name: "media_kit_libs_ios_video",
    platforms: [
        .iOS("9.0")
    ],
    products: [
        .library(name: "media-kit-libs-ios-video", targets: libmpvProductTargets),
        .library(name: "Mpv", targets: ["Mpv"])
    ],
    dependencies: [],
    targets: libmpvTargets.map { framework in
        .binaryTarget(
            name: framework,
            url: "\(libmpvArtifactBase)_\(framework).zip",
            checksum: libmpvChecksums[framework]!
        )
    } + [
        .target(
            name: "media_kit_libs_ios_video",
            dependencies: libmpvTargets.map { framework in .target(name: framework) },
            resources: [
                .process("PrivacyInfo.xcprivacy")
            ]
        )
    ]
)
