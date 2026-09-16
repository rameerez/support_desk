# frozen_string_literal: true

module Madmin
  # Stands in for the base controller a real admin framework gives you —
  # madmin's own `Madmin::ApplicationController`, Avo's, or your own. The
  # console generator's controller inherits from it, which is the whole
  # point of Layer 2: the host's auth, layout and helpers apply, and the
  # gem supplies only the verbs.
  class ApplicationController < ::ApplicationController
  end
end
