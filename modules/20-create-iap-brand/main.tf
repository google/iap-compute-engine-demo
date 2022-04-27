# Copyright 2022 Google LLC
# 
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# 
#     https://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# This module is used to create the IAP OAuth brand for the IAP demo.
# There currently can only be one brand per Google Cloud project.  Since
# brands cannot be deleted from projects, building out this Terraform plan
# will fail on subseequent attempts will trigger an error.  Moving the brand
# resource to a separate module prevents the build of the 90-build-demo module
# from aborting.

module "global_variables" {
  source = "../00-global-variables"
}

resource "google_iap_brand" "demo_iap_brand" {
  support_email = module.global_variables.iap_test_user
  application_title = "IAP Demo"
}
