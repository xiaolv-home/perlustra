import Foundation

/// Static knowledge about file extensions and special file names.
public enum ExtensionTable {
    public static let pdf: Set<String> = ["pdf", "ai"]

    public static let rawImage: Set<String> = [
        "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "dng", "raf", "orf", "rw2", "pef",
        "srw", "x3f", "3fr", "erf", "kdc", "mrw", "mos", "iiq", "rwl", "dcr", "fff", "mef", "raw",
    ]

    public static let image: Set<String> = Set([
        "jpg", "jpeg", "jpe", "jfif", "png", "apng", "gif", "webp", "heic", "heif", "hif", "avif", "tif",
        "tiff", "bmp", "dib", "ico", "icns", "cur", "psd", "tga", "exr", "hdr", "jp2", "j2k", "jpf",
        "jpx", "dds", "pbm", "pgm", "ppm", "pnm", "jxl", "astc", "ktx", "sgi",
    ]).union(rawImage)

    public static let svg: Set<String> = ["svg", "svgz"]

    public static let video: Set<String> = [
        "mp4", "m4v", "mov", "qt", "mkv", "webm", "avi", "wmv", "flv", "f4v", "rmvb", "rm", "ts",
        "mts", "m2ts", "m2t", "mpg", "mpeg", "m2v", "vob", "3gp", "3g2", "ogv", "asf", "divx", "mxf",
        "y4m", "dv",
    ]

    public static let audio: Set<String> = [
        "mp3", "m4a", "m4b", "m4r", "aac", "adts", "flac", "wav", "wave", "aif", "aiff", "aifc", "caf",
        "ogg", "oga", "opus", "wma", "ape", "alac", "amr", "ac3", "eac3", "dts", "mka", "wv", "mp2",
        "mid", "midi", "au", "snd", "tta", "spx",
    ]

    /// Containers/codecs AVFoundation cannot play; these go to mpv first.
    public static let mpvPreferred: Set<String> = [
        "mkv", "webm", "avi", "wmv", "flv", "f4v", "rmvb", "rm", "ts", "mts", "m2ts", "m2t", "vob",
        "ogv", "asf", "divx", "mxf", "y4m", "ogg", "oga", "opus", "wma", "ape", "mka", "wv", "dts",
        "tta", "spx", "mpg", "mpeg", "m2v",
    ]

    public static let markdown: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn", "mdwn", "mdx"]
    public static let json: Set<String> = ["json", "geojson", "webmanifest", "har", "jsonc", "json5", "topojson"]
    public static let plist: Set<String> = ["plist", "entitlements", "mobileprovision_plist"]
    public static let csv: Set<String> = ["csv"]
    public static let tsv: Set<String> = ["tsv", "tab"]
    public static let html: Set<String> = ["html", "htm", "xhtml", "shtml"]
    public static let sqlite: Set<String> = ["sqlite", "sqlite3", "db3", "s3db", "sl3"]
    public static let font: Set<String> = ["ttf", "otf", "ttc", "otc", "woff", "woff2", "dfont"]

    public static let archive: Set<String> = [
        "zip", "7z", "rar", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "lz4", "zst",
        "tzst", "lzma", "tlz", "z", "cpio", "iso", "xar", "jar", "war", "ear", "apk", "ipa", "cab",
        "lha", "lzh", "deb", "rpm", "cbz", "cbr", "cb7", "xip", "aar", "whl", "nupkg", "vsix", "crx",
    ]

    public static let iwork: [String: IWorkKind] = ["pages": .pages, "key": .keynote, "numbers": .numbers]

    public static let office: Set<String> = [
        "doc", "docx", "docm", "dot", "dotx", "dotm", "xls", "xlsx", "xlsm", "xlsb", "xlt", "xltx",
        "ppt", "pptx", "pptm", "pps", "ppsx", "pot", "potx", "rtf", "rtfd", "odt", "ods", "odp", "wps", "et", "dps",
    ]

    /// Anything else Quick Look is known to render well.
    public static let quicklook: Set<String> = [
        "usdz", "usd", "usda", "usdc", "reality", "scn", "dae", "abc", "obj", "stl", "ply",
        "epub", "vcf", "ics", "eml", "emlx", "webarchive", "pkpass", "key-tef", "numbers-tef",
        "pages-tef", "sketch", "afphoto", "afdesign", "pxm", "graffle", "xd",
    ]

    /// Extension → highlighter language id.
    public static let language: [String: String] = {
        var m: [String: String] = [:]
        func add(_ lang: String, _ exts: [String]) { for e in exts { m[e] = lang } }
        add("swift", ["swift", "swiftinterface"])
        add("python", ["py", "pyw", "pyi", "pyx", "gyp", "bzl", "star"])
        add("javascript", ["js", "mjs", "cjs", "jsx"])
        add("typescript", ["ts", "tsx", "mts", "cts"])
        add("shell", ["sh", "bash", "zsh", "fish", "ksh", "csh", "tcsh", "command", "tool", "zshrc", "bashrc", "profile", "zprofile", "bash_profile", "envrc"])
        add("c", ["c", "h", "m", "i"])
        add("cpp", ["cc", "cpp", "cxx", "c++", "hpp", "hh", "hxx", "h++", "mm", "ino", "cu", "cuh", "metal", "ipp", "tpp"])
        add("java", ["java", "gradle", "groovy"])
        add("kotlin", ["kt", "kts"])
        add("go", ["go"])
        add("rust", ["rs"])
        add("ruby", ["rb", "rake", "gemspec", "podspec", "ru"])
        add("php", ["php", "phtml"])
        add("csharp", ["cs", "csx"])
        add("sql", ["sql", "ddl", "dml", "hql", "psql", "mysql", "pls", "plsql", "pkb", "pks"])
        add("lua", ["lua"])
        add("perl", ["pl", "pm", "t"])
        add("r", ["r", "rmd"])
        add("scala", ["scala", "sc"])
        add("dart", ["dart"])
        add("json", ["jsonl", "ndjson", "ipynb", "babelrc", "eslintrc", "prettierrc"])
        add("yaml", ["yml", "yaml"])
        add("toml", ["toml"])
        add("ini", ["ini", "cfg", "conf", "properties", "env", "editorconfig", "gitconfig", "desktop", "service", "reg", "inf", "npmrc"])
        add(
            "xml",
            [
                "xml", "xsd", "xsl", "xslt", "storyboard", "xib", "csproj", "vcxproj", "fsproj", "plist_xml", "rss", "atom", "opml", "gpx", "kml", "xliff",
                "xlf", "resx", "pom", "nuspec", "wsdl", "dtd", "xaml",
            ])
        add("html", ["vue", "svelte", "erb", "ejs", "hbs", "jinja", "j2", "twig", "astro"])
        add("css", ["css", "scss", "sass", "less", "styl"])
        add("makefile", ["mk", "mak", "make"])
        add("dockerfile", ["dockerfile", "containerfile"])
        add("diff", ["diff", "patch", "rej"])
        add("log", ["log", "out", "err"])
        add("haskell", ["hs", "lhs"])
        add("elixir", ["ex", "exs"])
        add("clojure", ["clj", "cljs", "cljc", "edn"])
        add("powershell", ["ps1", "psm1", "psd1"])
        add("batch", ["bat", "cmd"])
        add("vim", ["vim", "vimrc"])
        add("tex", ["tex", "sty", "cls", "bib", "ltx"])
        add("protobuf", ["proto"])
        add("graphql", ["graphql", "gql"])
        add("terraform", ["tf", "tfvars", "hcl"])
        add("zig", ["zig"])
        add("nim", ["nim"])
        add("julia", ["jl"])
        add("objc", [])
        add("asm", ["s", "asm"])
        add("cmake", ["cmake"])
        add(
            "plain",
            [
                "txt", "text", "nfo", "me", "1st", "readme", "srt", "vtt", "ass", "ssa", "sub", "lrc", "cue", "m3u", "m3u8", "pls", "strings", "po", "rst",
                "adoc", "asciidoc", "org", "textile", "license", "authors", "changelog", "todo", "gitignore", "gitattributes", "dockerignore", "npmignore",
                "pem", "crt", "pub", "asc", "sig", "manifest", "list", "sum", "mod", "nix", "spec", "in", "am", "ac", "pbxproj", "xcconfig", "modulemap", "def",
            ])
        return m
    }()

    /// Well-known extensionless file names.
    public static let specialNames: [String: String] = [
        "makefile": "makefile", "gnumakefile": "makefile", "dockerfile": "dockerfile",
        "containerfile": "dockerfile", "gemfile": "ruby", "rakefile": "ruby", "podfile": "ruby",
        "brewfile": "ruby", "vagrantfile": "ruby", "fastfile": "ruby", "appfile": "ruby",
        "cmakelists.txt": "cmake", "package.swift": "swift", "jenkinsfile": "java",
        ".zshrc": "shell", ".bashrc": "shell", ".bash_profile": "shell", ".profile": "shell",
        ".zprofile": "shell", ".zshenv": "shell", ".gitignore": "plain", ".gitconfig": "ini",
        ".editorconfig": "ini", ".env": "ini", "license": "plain", "readme": "plain",
        "authors": "plain", "changelog": "plain", "copying": "plain", "notice": "plain",
        "procfile": "plain", "caddyfile": "plain", ".vimrc": "vim", "go.mod": "plain", "go.sum": "plain",
        "cargo.lock": "toml", "pipfile": "toml", "hosts": "plain", "crontab": "shell",
    ]

    public static func languageDisplayName(_ lang: String) -> String {
        switch lang {
        case "swift": return "Swift"
        case "python": return "Python"
        case "javascript": return "JavaScript"
        case "typescript": return "TypeScript"
        case "shell": return "Shell"
        case "c": return "C"
        case "cpp": return "C++"
        case "java": return "Java"
        case "kotlin": return "Kotlin"
        case "go": return "Go"
        case "rust": return "Rust"
        case "ruby": return "Ruby"
        case "php": return "PHP"
        case "csharp": return "C#"
        case "sql": return "SQL"
        case "lua": return "Lua"
        case "perl": return "Perl"
        case "r": return "R"
        case "scala": return "Scala"
        case "dart": return "Dart"
        case "json": return "JSON"
        case "yaml": return "YAML"
        case "toml": return "TOML"
        case "ini": return "INI"
        case "xml": return "XML"
        case "html": return "HTML"
        case "css": return "CSS"
        case "makefile": return "Makefile"
        case "dockerfile": return "Dockerfile"
        case "diff": return "Diff"
        case "log": return "日志"
        case "markdown": return "Markdown"
        case "haskell": return "Haskell"
        case "elixir": return "Elixir"
        case "clojure": return "Clojure"
        case "powershell": return "PowerShell"
        case "batch": return "Batch"
        case "tex": return "TeX"
        case "protobuf": return "Protobuf"
        case "graphql": return "GraphQL"
        case "terraform": return "HCL"
        case "asm": return "汇编"
        case "cmake": return "CMake"
        default: return "纯文本"
        }
    }
}
