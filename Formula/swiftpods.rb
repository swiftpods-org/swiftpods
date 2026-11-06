class Swiftpods < Formula
  desc "Dependency manager for Apple platform projects"
  homepage "https://swiftpods.org"
  if Hardware::CPU.arm?
    url "https://github.com/swiftpods-org/swiftpods/releases/download/v0.3.12/swiftpods-0.3.12-macos-13.0-arm64.zip"
    sha256 "2a1bcb99c3057c8861333c7fe23a694a1f59580a060bb81ddc9ca73934212cec"
  else
    url "https://github.com/swiftpods-org/swiftpods/releases/download/v0.3.12/swiftpods-0.3.12-macos-13.0-x86_64.zip"
    sha256 "0d0608ccbc9fed5d58e3e85289a72786ef6186e2643217075ea67f961bed1743"
  end
  version "0.3.12"
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
