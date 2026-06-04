variable "name" { type = string }
variable "vpc_id" { type = string }
variable "subnet_ids" { type = list(string) }
variable "db_name" { type = string }
variable "db_username" { type = string }
variable "max_capacity" {
  type    = number
  default = 4
}
variable "skip_final_snapshot" {
  type    = bool
  default = false
}
