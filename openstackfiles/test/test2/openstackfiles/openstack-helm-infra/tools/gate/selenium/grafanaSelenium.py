# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at

#    http://www.apache.org/licenses/LICENSE-2.0

# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import sys
from selenium.webdriver.common.by import By
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC
from selenium.common.exceptions import TimeoutException
from selenium.common.exceptions import NoSuchElementException
from seleniumtester import SeleniumTester

st = SeleniumTester('Grafana')

username = st.get_variable('GRAFANA_USER')
password = st.get_variable('GRAFANA_PASSWORD')
grafana_uri = st.get_variable('GRAFANA_URI')

try:
    st.logger.info('Attempting to connect to Grafana')
    st.browser.get(grafana_uri)
    el = WebDriverWait(st.browser, 15).until(
        EC.title_contains('Grafana')
    )
    st.logger.info('Connected to Grafana')
except TimeoutException:
    st.logger.critical('Timed out waiting to connect to Grafana')
    st.browser.quit()
    sys.exit(1)

logger.info("Attempting to log into Grafana dashboard")
try:
    browser.find_element_by_name('user').send_keys(username)
    browser.find_element_by_name('password').send_keys(password)
    browser.find_element_by_class_name('css-6ntnx5-button').click()
    logger.info("Successfully logged in to Grafana")
except NoSuchElementException:
    logger.error("Failed to log in to Grafana")
    browser.quit()
    sys.exit(1)

st.browser.quit()
