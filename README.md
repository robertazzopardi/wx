# wx - Watcher

`wx` is a small and efficient file watcher that hot reloads the provided executable when files in a given directory change.

## Features

- Watches directories recursively for file changes
- Respects `.gitignore` rules to avoid irrelevant files
- Uses an alternate screen buffer for clean command output
- Automatically restarts commands when file changes are detected

## Installation

### Prerequisites

- [Zig](https://ziglang.org/) Built on 0.14.0 not tested on earlier versions and will try to track future zig versions.

### Building from source

```bash
git clone https://github.com/robertazzopardi/wx.git
cd wx
zig build -Doptimize=ReleaseSafe
```

The executable will be available at `zig-out/bin/wx`

Use `install --prefix` to install the binary to a specific location.

```bash
zig build install -Doptimize=ReleaseSafe -p ~/.local
```

## Usage

```bash
wx <command> [args...]
```

### Examples

Watch and run your Zig application:
```bash
wx zig build run
```

Watch and run tests:
```bash
wx zig test src/main.zig
```

Watch and build:
```bash
wx zig build
```

## Why another hot reload program?

There are many out there, but none of the ones that I tried did exactly what I wanted. I found that hot reloading tui applications did not work quite right in other similar project which might have been a skill issue but here we are.

## Contributing

Contributions are welcome! Feel free to open issues or submit pull requests. See [CONTRIBUTING.md](CONTRIBUTING.md).
