using System;
using System.Collections.Generic;
using System.ComponentModel.DataAnnotations;
using System.Linq;
using System.Reflection;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;

namespace RPA.CPH.NonSubsidy.Domain.Attributes
{
    public class GridReference : ValidationAttribute
    {
        protected override ValidationResult IsValid(object value, ValidationContext validationContext)
        {
            object instance = validationContext.ObjectInstance;

            Type type = instance.GetType();

            PropertyInfo activeProperty = type.GetProperty("Active");
            PropertyInfo landParcelIdProperty = type.GetProperty("LandParcelId");

            object activePropertyValue = activeProperty.GetValue(instance);
            object landParcelIdPropertyValue = landParcelIdProperty.GetValue(instance);

            bool active = (bool)activePropertyValue;
            int landParcelId = (int)landParcelIdPropertyValue;

            bool flag = false;

            if (!active || (landParcelId == 0 && value == null))
            {
                flag = true;
            }
            else if (value != null && Regex.IsMatch(value.ToString(), "^[A-z][A-z][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]$"))
            {
                flag = true;
            }

            if (!flag)
            {
                ValidationResult result = new ValidationResult("Invalid Grid Reference.");

                return result;
            }
            else
            {
                return null;
            }
        }
    }
}
