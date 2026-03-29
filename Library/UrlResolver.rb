class UrlResolver
  def initialize(version, mode)
    @version = version
    @formula_root = mode == "local" ? Dir.pwd : File.expand_path("..", __dir__)
  end

  def patch_url name
    "#{@formula_root}/patches/emacs-#@version/#{name}.patch"
  end

  def icon_url name
    "#{@formula_root}/icons/#{name}.icns"
  end
end
