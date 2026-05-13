import { addMinutes, epochSecondsToIdentDate, normalizeIdentDate } from '../date.js';
import { stripEmpty } from './contracts.js';

export function leadToIdentTicket(lead, contact, config) {
  const fields = config.amo.fields;
  const planStart = fieldValueById(lead, fields.planStart);
  const normalizedPlanStart = normalizeIdentDate(planStart);
  const normalizedPlanEnd =
    normalizeIdentDate(fieldValueById(lead, fields.planEnd)) ||
    (normalizedPlanStart ? addMinutes(normalizedPlanStart, config.amo.defaultAppointmentMinutes) : null);

  const ticketDateEpoch = config.amo.ticketDateSource === 'created_at' ? lead.created_at : lead.updated_at;
  const contactName = contact?.name || [contact?.last_name, contact?.first_name].filter(Boolean).join(' ');

  return stripEmpty({
    Id: `amo:${lead.id}`,
    DateAndTime: epochSecondsToIdentDate(ticketDateEpoch) || normalizeIdentDate(new Date().toISOString()),
    ClientPhone: phoneFromContact(contact) || fieldValueByCode(lead, 'PHONE'),
    ClientEmail: emailFromContact(contact) || fieldValueByCode(lead, 'EMAIL'),
    FormName: fieldValueById(lead, fields.formName) || 'amoCRM',
    ClientFullName: contactName || lead.name,
    PlanStart: normalizedPlanStart,
    PlanEnd: normalizedPlanEnd,
    Comment: fieldValueById(lead, fields.comment),
    DoctorId: asInt(fieldValueById(lead, fields.doctorId)),
    DoctorName: fieldValueById(lead, fields.doctorName),
    AmoDoctorId: fieldValueById(lead, fields.doctorAmoId),
    UtmSource: fieldValueById(lead, fields.utmSource),
    UtmMedium: fieldValueById(lead, fields.utmMedium),
    UtmCampaign: fieldValueById(lead, fields.utmCampaign),
    UtmTerm: fieldValueById(lead, fields.utmTerm),
    UtmContent: fieldValueById(lead, fields.utmContent),
    HttpReferer: fieldValueById(lead, fields.httpReferer)
  });
}

export function bookingToAmoLead(ticket, config) {
  const customFields = [];
  addCustomField(customFields, config.amo.fields.planStart, ticket.PlanStart);
  addCustomField(customFields, config.amo.fields.planEnd, ticket.PlanEnd);
  addCustomField(customFields, config.amo.fields.doctorId, ticket.DoctorId);
  addCustomField(customFields, config.amo.fields.doctorName, ticket.DoctorName);
  addCustomField(customFields, config.amo.fields.comment, ticket.Comment);
  addCustomField(customFields, config.amo.fields.formName, ticket.FormName);
  addCustomField(customFields, config.amo.fields.utmSource, ticket.UtmSource);
  addCustomField(customFields, config.amo.fields.utmMedium, ticket.UtmMedium);
  addCustomField(customFields, config.amo.fields.utmCampaign, ticket.UtmCampaign);
  addCustomField(customFields, config.amo.fields.utmTerm, ticket.UtmTerm);
  addCustomField(customFields, config.amo.fields.utmContent, ticket.UtmContent);
  addCustomField(customFields, config.amo.fields.httpReferer, ticket.HttpReferer);

  const lead = stripEmpty({
    name: `Запись IDENT: ${ticket.ClientFullName}`,
    pipeline_id: config.amo.createPipelineId,
    status_id: config.amo.createStatusId,
    custom_fields_values: customFields.length ? customFields : undefined,
    tags_to_add: config.amo.createTag ? [{ name: config.amo.createTag }] : undefined,
    _embedded: {
      contacts: [
        {
          name: ticket.ClientFullName,
          custom_fields_values: [
            {
              field_code: 'PHONE',
              values: [{ value: ticket.ClientPhone, enum_code: 'WORK' }]
            },
            ...(ticket.ClientEmail
              ? [
                  {
                    field_code: 'EMAIL',
                    values: [{ value: ticket.ClientEmail, enum_code: 'WORK' }]
                  }
                ]
              : [])
          ]
        }
      ]
    }
  });

  return lead;
}

export function fieldValueById(entity, fieldId) {
  if (!fieldId) return null;
  const field = entity?.custom_fields_values?.find((item) => Number(item.field_id) === Number(fieldId));
  return firstCustomFieldValue(field);
}

export function fieldValueByCode(entity, code) {
  const field = entity?.custom_fields_values?.find((item) => item.field_code === code);
  return firstCustomFieldValue(field);
}

export function phoneFromContact(contact) {
  return fieldValueByCode(contact, 'PHONE');
}

export function emailFromContact(contact) {
  return fieldValueByCode(contact, 'EMAIL');
}

function firstCustomFieldValue(field) {
  const value = field?.values?.[0]?.value;
  if (value === undefined || value === null || value === '') return null;
  return value;
}

function addCustomField(collection, fieldId, value) {
  if (!fieldId || value === undefined || value === null || value === '') return;
  collection.push({
    field_id: Number(fieldId),
    values: [{ value }]
  });
}

function asInt(value) {
  if (value === undefined || value === null || value === '') return null;
  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) ? parsed : null;
}
