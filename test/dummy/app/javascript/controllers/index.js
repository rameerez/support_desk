// The stock stimulus-rails loader: registers every controllers/*_controller
// pin in the importmap, chats' controllers/chats/* included.
import { application } from "controllers/application"
import { eagerLoadControllersFrom } from "@hotwired/stimulus-loading"

eagerLoadControllersFrom("controllers", application)
