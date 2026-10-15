require 'spec_helper'

describe 'SwiftPods baseline installation-option contract' do
  it 'preserves each boolean alias and its baseline default/explicit value' do
    defaults = Pod::Installer::InstallationOptions.new
    Pod::Installer::InstallationOptions.defaults.each do |name, value|
      predicate = "#{name}?"
      next unless defaults.respond_to?(predicate)
      defaults.public_send(predicate).should.equal(defaults.public_send(name))
      if value == true || value == false
        explicit = Pod::Installer::InstallationOptions.new(name => !value)
        explicit.public_send(name).should.equal(!value)
        explicit.public_send(predicate).should.equal(!value)
      end
    end
  end

  it 'gives equal option values equal hashes across independently created instances' do
    first = Pod::Installer::InstallationOptions.new('clean' => false)
    second = Pod::Installer::InstallationOptions.new('clean' => false)
    first.eql(second).should.equal(true)
    first.hash.should.equal(second.hash)
  end

  it 'rejects an unknown option instead of silently dropping it' do
    lambda { Pod::Installer::InstallationOptions.new('not_a_baseline_option' => true) }.should.raise(Pod::Informative)
  end
end
