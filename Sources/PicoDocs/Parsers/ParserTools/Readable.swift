//
//  Readable.swift
//  Pico
//
//  Created by Ronald Mannak on 4/19/24.
//

import Foundation

public struct Readable: Codable, Sendable {
    
    /// Article title
    public let title: String
    
    /// HTML string of processed article content
    public let content: String

    /// Text content of the article, with all the HTML tags removed
    public let textContent: String
    
    /// Length of an article, in characters
    public let length: Int

    /// Article description, or short excerpt from the content
    public let excerpt: String?
    
    /// Author metadata
    public let byline: String?
    
    /// Content direction
    public let dir: String?

    /// Name of the site
    public let siteName: String?

    /// Content language
    public let lang: String?
    
    /// Published time
//    let publishedTime: Date? // TODO: convert to time
}


/*
 ["siteName": InsideEVs, "length": 2199, "publishedTime": 2024-04-19T20:00:09Z, "excerpt": Electrification progresses at various rates depending on the region and it will lead to an interesting disproportion of electric vehicle deployment in the U.S., "content": <div id="readability-page-1" class="page"><div id="post_box"> <div> <p><span data-time="1713542409"></span><span>Apr 19, 2024</span><span> at</span> 4:00pm ET</p>  </div> <div> <p>Electrification progresses at various rates depending on the region&nbsp;and&nbsp;it will lead&nbsp;to an&nbsp;interesting&nbsp;disproportion of electric vehicle deployment in the U.S.</p> <p>According to <a href="https://www.nrel.gov/docs/fy23osti/85654.pdf" target="_blank" rel="noopener noreferrer">the National Renewable Energy Laboratory's study</a>,&nbsp;highlighted by the DOE's Vehicle Technologies Office, the majority of the EV fleet will be located in suburban areas. The study says about 60% out of the&nbsp;projected 33 million vehicles by 2030 will be in suburban areas. That's almost 20 million EVs.</p> <div contenteditable="false" draggable="true" data-widget="infobox"> <p>EV fleet in the U.S.</p> <p>Currently, all-electric vehicles represent almost 8% percent of new light-duty vehicle registrations in the U.S. The share of EVs in the total fleet is even smaller, but in a decade, it's expected to be noticeable.</p> </div> <p>The remaining 40% of EVs are expected to be located in rural locations (20%) and urban areas (20%).</p> <p>If true, it indicates that most EV customers will be people who need a car for commuting. Suburban locations usually mean houses with private parking spots&nbsp;and home charging options. This seems to be a core market for EVs.</p> <p>On the other hand, in urban areas—where the zero-emission feature is very important—potential customers usually do not have a home charging point and their mileage might be lower, which means that the higher price of an EV isn't offset by lower energy/fuel cost.</p> <p>The study also indicates&nbsp;that in urban areas, 40% of EV electricity needs (energy dispensed) will fall on public <a href="https://insideevs.com/tag/fast-charging/" data-inline-widget="internal-links" data-type-id="7" data-params="%7B%22tag%22%3A%22DC%20fast%20chargers%22%2C%22originalTitle%22%3A%22fast%20charging%22%2C%22alias%22%3A%22fast-charging%22%7D">DC fast chargers</a> (150 kilowatts or higher), compared to just 20% in suburban areas and 10% in rural areas.</p> <p>In all cases, AC Level 2 charging (with some addition of AC Level 1) will be the primary charging type.</p>  <section contenteditable="false" draggable="true" data-widget="special_image" data-align="center"> <p><a href="https://cdn.motor1.com/images/custom/2030-ev-fleet-by-community-category-and-relative-share-of-electricity-by-charging-type-source-energ.png"> <img draggable="false" src="https://cdn.motor1.com/images/custom/thumbnail/2030-ev-fleet-by-community-category-and-relative-share-of-electricity-by-charging-type-source-energ.png" alt="2030-ev-fleet-by-community-category-and-relative-share-of-electricity-by-charging-type-source-energ" width="820" height="400" loading="lazy"> </a></p> </section> <blockquote> <p>Notes:</p> <ul> <li>Level 1 (L1) refers to 120V AC charging from a typical US household outlet.</li> <li>Level 2 (L2) refers to 240V AC charging like that used for a household electric dryer.</li> <li>DC fast charging in this study refers to charge rates of 150 kW or higher.</li> <li>Low power DC charging (e.g., 50 kW) is omitted from the study’s baseline scenario on the basis of assumed driver preferences for DC charging that is as fast as possible and 2030 vehicle technology scenarios where batteries are capable of accepting at least 150 kW of peak power.</li> </ul> </blockquote>  <section contenteditable="false" draggable="true" data-widget="related-content" data-widget-size="content" data-params="%7B%22type_id%22%3A0%2C%22title_id%22%3A%22%22%2C%22items%22%3A%5B%7B%22article_edition_id%22%3A%22712951%22%2C%22title%22%3A%22This%20Is%20How%20Much%20EV%20Charging%20The%20U.S.%20Will%20Need%20By%202030%22%2C%22alias%22%3A%22ev-charging-ports-us-need-2030%22%2C%22section%22%3A%221%22%2C%22is_video%22%3A%220%22%2C%22images%22%3A%7B%22s5%22%3A%22https%3A%2F%2Fcdn.motor1.com%2Fimages%2Fmgl%2FQe3eoY%2Fs5%2Fnyc-500-kw-gravity-charging-center2.jpg%22%7D%7D%2C%7B%22article_edition_id%22%3A%22687300%22%2C%22title%22%3A%22Electric%20Vehicles%20Could%20Enjoy%20Up%20To%2086%25%20Global%20Market%20Share%20By%202030%3A%20Report%22%2C%22alias%22%3A%22falling-battery-prices-to-spur-ev-demand%22%2C%22section%22%3A%221%22%2C%22is_video%22%3A%220%22%2C%22images%22%3A%7B%22s5%22%3A%22https%3A%2F%2Fcdn.motor1.com%2Fimages%2Fmgl%2F40mboJ%2Fs5%2Ftesla-model-3-and-y.jpg%22%7D%7D%5D%7D"> <p>See also</p>  </section> </div> </div></div>, "lang": en, "textContent":   Apr 19, 2024 at 4:00pm ET    Electrification progresses at various rates depending on the region and it will lead to an interesting disproportion of electric vehicle deployment in the U.S. According to the National Renewable Energy Laboratory's study, highlighted by the DOE's Vehicle Technologies Office, the majority of the EV fleet will be located in suburban areas. The study says about 60% out of the projected 33 million vehicles by 2030 will be in suburban areas. That's almost 20 million EVs.  EV fleet in the U.S. Currently, all-electric vehicles represent almost 8% percent of new light-duty vehicle registrations in the U.S. The share of EVs in the total fleet is even smaller, but in a decade, it's expected to be noticeable.  The remaining 40% of EVs are expected to be located in rural locations (20%) and urban areas (20%). If true, it indicates that most EV customers will be people who need a car for commuting. Suburban locations usually mean houses with private parking spots and home charging options. This seems to be a core market for EVs. On the other hand, in urban areas—where the zero-emission feature is very important—potential customers usually do not have a home charging point and their mileage might be lower, which means that the higher price of an EV isn't offset by lower energy/fuel cost. The study also indicates that in urban areas, 40% of EV electricity needs (energy dispensed) will fall on public DC fast chargers (150 kilowatts or higher), compared to just 20% in suburban areas and 10% in rural areas. In all cases, AC Level 2 charging (with some addition of AC Level 1) will be the primary charging type.        Notes:  Level 1 (L1) refers to 120V AC charging from a typical US household outlet. Level 2 (L2) refers to 240V AC charging like that used for a household electric dryer. DC fast charging in this study refers to charge rates of 150 kW or higher. Low power DC charging (e.g., 50 kW) is omitted from the study’s baseline scenario on the basis of assumed driver preferences for DC charging that is as fast as possible and 2030 vehicle technology scenarios where batteries are capable of accepting at least 150 kW of peak power.     See also    , "dir": <null>, "byline": Mark Kane, "title": Most U.S. EVs Are Expected To Be In Suburban Areas In 2030]
 */
