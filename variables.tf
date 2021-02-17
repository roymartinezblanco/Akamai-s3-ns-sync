variable "bucket" {
  type = string
}

variable "projectname" {
  default = "akamNestorageSync"
}

variable "accountid"{
  type = string
}
variable "cpcode" {
  type = string
}


variable "region" {
  type = string
}

variable "secret" {

  type = map(string)
}