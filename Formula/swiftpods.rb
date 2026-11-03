class Swiftpods < Formula
  desc "Dependency manager for Apple platform projects"
  homepage "https://swiftpods.org"
  if Hardware::CPU.arm?
    url "https://github.com/swiftpods-org/swiftpods/releases/download/v0.3.11/swiftpods-0.3.11-macos-13.0-arm64.zip"
    sha256 "9065c1c3afe4baeac8f07fc1c46059a58be672d6fb50dc35621771d5c7f88fb7"
  else
    url "https://github.com/swiftpods-org/swiftpods/releases/download/v0.3.11/swiftpods-0.3.11-macos-13.0-x86_64.zip"
    sha256 "7e832b7f292e97a8f9d0aafdf0ddf7c87ec7ab17462ff2c9342317ad973c08f4"
  end
  version "0.3.11"
  license "MIT"

  depends_on :macos

  def install
    minimum = { "arm64" => "13.0", "x86_64" => "13.0" }
    architecture = Hardware::CPU.arm? ? "arm64" : "x86_64"
    odie "No release for this architecture" unless minimum.key?(architecture)
    odie "Requires macOS #{minimum.fetch(architecture)} or newer" if MacOS.version < minimum.fetch(architecture)
    bin.install "bin/swiftpods"
    prefix.install "LICENSE", "README.md"
  end

  test do
    assert_equal version.to_s, shell_output("#{bin}/swiftpods version").strip
  end
end
