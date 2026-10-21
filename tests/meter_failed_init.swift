let rate = UInt32(CommandLine.arguments[1])!
if let m = LoudnessMeter(sampleRate: rate, channels: 2) { print("built at \(rate): \(m.channels) ch") } else { print("init returned nil at \(rate), and nothing crashed") }
