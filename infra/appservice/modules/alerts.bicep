targetScope = 'resourceGroup'

param stem string
param tags object
param siteResourceId string
param planResourceId string

@description('Email recipients for alerts. An empty list creates the alert rules without notification routing; routing is the receiving team\'s decision.')
param alertEmailAddresses array

var hasRecipients = !empty(alertEmailAddresses)

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = if (hasRecipients) {
  name: '${stem}-alerts'
  location: 'global'
  tags: tags
  properties: {
    groupShortName: take(replace(stem, '-', ''), 12)
    enabled: true
    emailReceivers: [
      for (address, index) in alertEmailAddresses: {
        name: 'recipient-${index}'
        emailAddress: address
        useCommonAlertSchema: true
      }
    ]
  }
}

var actions = hasRecipients ? [{ actionGroupId: actionGroup.id }] : []

resource http5xx 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: '${stem}-http-5xx'
  location: 'global'
  tags: tags
  properties: {
    description: 'Server errors (HTTP 5xx) above threshold.'
    severity: 2
    enabled: true
    scopes: [siteResourceId]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'Http5xx'
          metricName: 'Http5xx'
          metricNamespace: 'Microsoft.Web/sites'
          operator: 'GreaterThan'
          threshold: 10
          timeAggregation: 'Total'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: actions
  }
}

resource healthCheck 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: '${stem}-health-check'
  location: 'global'
  tags: tags
  properties: {
    description: 'App Service health check (/health/ready) reports unhealthy instances.'
    severity: 1
    enabled: true
    scopes: [siteResourceId]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'HealthCheckStatus'
          metricName: 'HealthCheckStatus'
          metricNamespace: 'Microsoft.Web/sites'
          operator: 'LessThan'
          threshold: 100
          timeAggregation: 'Average'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: actions
  }
}

resource responseTime 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: '${stem}-response-time'
  location: 'global'
  tags: tags
  properties: {
    description: 'Average response time above 3 seconds.'
    severity: 3
    enabled: true
    scopes: [siteResourceId]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'HttpResponseTime'
          metricName: 'HttpResponseTime'
          metricNamespace: 'Microsoft.Web/sites'
          operator: 'GreaterThan'
          threshold: 3
          timeAggregation: 'Average'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: actions
  }
}

resource planCpu 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: '${stem}-plan-cpu'
  location: 'global'
  tags: tags
  properties: {
    description: 'App Service plan CPU above 85% for 15 minutes.'
    severity: 3
    enabled: true
    scopes: [planResourceId]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'CpuPercentage'
          metricName: 'CpuPercentage'
          metricNamespace: 'Microsoft.Web/serverfarms'
          operator: 'GreaterThan'
          threshold: 85
          timeAggregation: 'Average'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: actions
  }
}

resource planMemory 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: '${stem}-plan-memory'
  location: 'global'
  tags: tags
  properties: {
    description: 'App Service plan memory above 85% for 15 minutes.'
    severity: 3
    enabled: true
    scopes: [planResourceId]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'MemoryPercentage'
          metricName: 'MemoryPercentage'
          metricNamespace: 'Microsoft.Web/serverfarms'
          operator: 'GreaterThan'
          threshold: 85
          timeAggregation: 'Average'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: actions
  }
}
