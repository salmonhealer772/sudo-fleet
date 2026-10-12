Feature: Compile a prose interest into a bounded company search query

  status-card-query turns a natural-language interest prompt ("Show me
  recent funding rounds for fintech startups in SF") into a structured,
  bounded CompanySearchQuery a status-card backend can execute. It is a
  PURE function — no network, no I/O, no side effects, deterministic.

  Background:
    Given the status-card-query module is available

  Scenario: Filler phrases are stripped
    Given the prompt "Show me recent funding rounds for fintech startups in SF"
    When I call compile_query with that prompt
    Then the query does not contain "show me"
    And the query contains "funding rounds"

  Scenario: Query is bounded to 120 characters
    Given the prompt "Find companies in healthtech"
    When I call compile_query with that prompt
    Then the query length is at most 120

  Scenario: A "top N" limit is extracted
    Given the prompt "Top 25 companies in healthtech"
    When I call compile_query with that prompt
    Then limit is 25
    And the query does not contain "top 25"

  Scenario: A limit above 50 is capped at 50
    Given the prompt "limit 100 companies"
    When I call compile_query with that prompt
    Then limit is 50

  Scenario: key=value filters are extracted
    Given the prompt "funding rounds sector=fintech region=SF"
    When I call compile_query with that prompt
    Then filters is {"sector": "fintech", "region": "SF"}
    And the query does not contain "sector=fintech"

  Scenario: Empty input yields the default query
    Given the prompt ""
    When I call compile_query with that prompt
    Then query is ""
    And filters is {}
    And limit is 10

  Scenario: Whitespace is collapsed
    Given the prompt "  too   much   whitespace  "
    When I call compile_query with that prompt
    Then query is "too much whitespace"

  Scenario: Very long query is truncated at 120 characters
    Given a prompt made of "companies " repeated 20 times
    When I call compile_query with that prompt
    Then the query length is 120
